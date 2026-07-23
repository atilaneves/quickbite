module ut.backends.runner.lang.expressions;


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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "CTFE @ShouldFail (assert formatter uses sprintf), see pin above"),
)) {
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

static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.diverges,
        "see Interpreter pin below; passes the real assertions instead " ~
        "of the CTFE-formatter ShouldFail"),
)) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "see Ctfe pin above; CTFE returns the bare identifier, compiled " ~
        "code the fully-qualified name"),
)) {
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

static foreach (backend; Matrix!()) {
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

// A `Base`-typed local holding a `Derived` object, a virtual call through
// that `Base` reference (dynamic dispatch must still reach
// `Derived.score`), a downcast to a `Derived`-typed local,
// the `Base` reference then nulled, and a field write through the downcast
// local that only `Derived` declares. The danger in this shape is one
// object identity reached through two DIFFERENT static types (`Base`, then
// `Derived`): `object_table.ObjectTable.storageFor` sizes the identity's
// body from whichever mirrors first (`Base`, narrower), so a later
// `Derived`-typed write would go through a too-small block with no bounds
// check of its own (`place.Place` has none) -- silent GC-heap corruption in
// a release build. `impl.d`'s `classBodyShapeMatches` declines a class
// mirror outright whenever a static type's name disagrees with the boxed
// value's own dynamic one (own header comment), so `Base b`'s own mirror
// never allocates the too-narrow body at all. The fixture pins a second
// property alongside it: declining `d`'s write while `b` still aliases it,
// then no longer declining once `b` is null, leaves `d`'s frame slot
// read/verified before its OWN first successful write ever ran, and
// `assertClassReferenceMirror`/`assertClassBodyValue` must skip rather than
// assert on such an all-zero, never-established slot/body (their own header
// comments).
static foreach (backend; Matrix!()) {
    @("class.downcastFieldWriteAfterVirtualCallThroughWiderStaticType." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Base {
                int baseField;

                int score() {
                    return baseField;
                }
            }

            class Derived : Base {
                int derivedField;

                override int score() {
                    return baseField + derivedField;
                }
            }

            int run(int seed) {
                Base b = new Derived();
                b.baseField = seed;

                const virtualScore = b.score();

                auto d = cast(Derived) b;
                b = null;

                d.derivedField = seed + 1;

                return virtualScore * 100 + d.score;
            }

            unittest {
                assert(run(10) == 1021);
            }
        });
    }
}

// The write/verify TIME asymmetry: `p`'s OWN mirror write declines
// (`classIdentityAliasedByAnotherBinding`, `impl.d`) while `y`'s object
// identity is still shared by another live binding, leaving `p`'s frame
// slot holding its PRIOR, unrelated object's address (from the earlier `p =
// new C(); p.x = seed;`, both unaliased at that point, so that write
// succeeded) rather than the never-written zero bytes the simpler "no other
// binding aliased it yet" case leaves behind. Nulling every OTHER binding
// of `y`'s identity afterwards is what makes the read side able to
// re-derive a DIFFERENT (non-declining) answer than the write saw: a
// verify step that re-runs the decline predicate at READ time finds nothing
// aliasing `y`'s identity any more, and goes on to compare `p`'s STALE,
// NON-zero frame slot (still the prior object's address) against a freshly
// composed expectation for `y`'s object -- a guaranteed "frame class
// reference mirror diverged from boxed local" `AssertError` on a correct
// guest program, and one no all-zero-slot skip can mask, since a stale
// non-null address is not all-zero. So `impl.d`'s `mirrorEstablished`
// records what `mirrorClassToFrame` actually did for `p`'s CURRENT binding
// at write time and `assertClassFrameMirror` trusts that instead of
// re-deriving: `p`'s write declined, so its later read never re-enters the
// mirror at all, regardless of what happens to `y`/`keepAlive` afterwards.
static foreach (backend; Matrix!()) {
    @("class.declinedMirrorWriteStaysDeclinedAfterAliasIsNulled." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C { int x; }

            C identity(C c) { return c; }

            int run(int seed) {
                auto p = new C();
                p.x = seed;

                auto y = new C();
                y.x = seed + 1;
                auto keepAlive = identity(y);
                p = identity(y);
                keepAlive = null;
                y = null;

                return p.x;
            }

            unittest {
                assert(run(10) == 11);
            }
        });
    }
}

// The rebind-invalidation counterpart of the fixture above, isolating the
// write/rebind/read sequence on its own: `p`'s FIRST write (unaliased)
// establishes its mirror, then `p`'s REBIND to `y`'s identity declines
// (`keepAlive` still aliases it at that exact moment) and must leave `p`
// with NO established mirror for its new binding -- catching a stale
// "we already wrote it" flag that (wrongly) survived from the FIRST
// binding, which `mirrorEstablished` (`impl.d`) is keyed and
// overwritten per write specifically to prevent (its own header comment).
// Never nulls `y`/`keepAlive`, unlike the fixture above: a stale flag
// would crash on THIS read already, with no need for the aliasing
// binding to disappear first.
static foreach (backend; Matrix!()) {
    @("class.declinedRebindDoesNotInheritPriorBindingsEstablishedMirror." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C { int x; }

            C identity(C c) { return c; }

            int run(int seed) {
                auto p = new C();
                p.x = seed;

                auto other = new C();
                other.x = seed + 1;
                auto keepAlive = identity(other);
                p = identity(other);

                return p.x;
            }

            unittest {
                assert(run(10) == 11);
            }
        });
    }
}

// The class-typed-FIELD counterpart of
// class.downcastFieldWriteAfterVirtualCallThroughWiderStaticType above:
// `Holder.field` is declared `Base` but references a `Derived` instance, so
// mirroring `holder` itself walks into that field with `impl.d`'s
// `classBodyShapeMatchesImpl` -- its own header comment names this exact
// nested-field decline (a class-typed field whose declared type
// disagrees with the boxed value's own dynamic class), the recursive
// sibling of that root-level decline.
static foreach (backend; Matrix!()) {
    @("class.downcastFieldWriteThroughFieldDeclaredAsWiderStaticType." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Base {
                int baseField;
            }

            class Derived : Base {
                int derivedField;
            }

            class Holder {
                Base field;
            }

            int run(int seed) {
                auto holder = new Holder();
                holder.field = new Derived();
                holder.field.baseField = seed;

                auto d = cast(Derived) holder.field;
                holder.field = null;

                d.derivedField = seed + 1;

                return d.baseField * 100 + d.derivedField;
            }

            unittest {
                assert(run(10) == 1011);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "see Ctfe pin above; CTFE rejects dg.ptr at compile time, " ~
        "compiled code returns a non-null context"),
)) {
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
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "see Ctfe pin above; CTFE rejects dg.funcptr at compile time, " ~
        "compiled code returns a plain function pointer"),
)) {
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

// Direct call syntax (`addToTotal(1)`, not `&nested`/a delegate variable) is
// the OTHER path a nested-function call reaches the walker through; this
// exercises it with two mutations of the same captured local, back to back.
static foreach (backend; Matrix!()) {
    @("function.nestedFunctionDirectlyMutatesEnclosingLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int accumulate(int seed) {
                int total = seed;

                void addToTotal(int value) {
                    total += value;
                }

                addToTotal(1);
                addToTotal(2);

                return total;
            }

            unittest {
                assert(accumulate(10) == 13);
            }
        });
    }
}

// Recursion means several activations of `recurse` are live at once, each
// with its own `total` local and its own `bump` activation reaching it --
// this fails if a nested function's captured-variable binding is ever
// resolved against the WRONG activation (e.g. the innermost or outermost
// one instead of its own direct caller).
static foreach (backend; Matrix!()) {
    @("function.nestedFunctionInsideRecursiveFunctionKeepsPerActivationCapture." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int recurse(int depth) {
                int total = depth * 10;

                void bump() {
                    total += 1;
                }

                if (depth > 0)
                    recurse(depth - 1);

                bump();

                return total;
            }

            unittest {
                assert(recurse(3) == 31);
            }
        });
    }
}

// Each recursive activation binds the same declaration AST anew. A pointer
// saved by the outer activation must keep naming that activation's local when
// the inner activation binds its own `x`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "CTFE resolves the caller pointer to the inner activation's x; see " ~
        "the Ctfe characterization pin below"),
    Omit!(Interpreter, Because.diverges,
        "boxed authorities are keyed by VarDeclaration, so recursive " ~
        "activations share x until the authority switch"),
)) {
    @("pointer.recursiveLocalAliasSurvivesInnerFreshBinding." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            int recurse(int depth, int* parent) {
                int x = seed(depth);
                int* current = &x;

                if (parent !is null)
                    *parent = seed(99);

                if (depth > 0)
                    recurse(depth - 1, current);

                return x;
            }

            unittest {
                assert(recurse(seed(1), null) == 99);
            }
        });
    }
}

// Ctfe resolves `parent` through the recursive declaration's current binding,
// so it updates the inner `x` and the outer call returns 1. This pins Ctfe's
// actual divergence; SystemLinker is the language-surface oracle above.
static foreach (backend; AliasSeq!(Ctfe)) {
    @("pointer.recursiveLocalAliasSurvivesInnerFreshBinding." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            int recurse(int depth, int* parent) {
                int x = seed(depth);
                int* current = &x;

                if (parent !is null)
                    *parent = seed(99);

                if (depth > 0)
                    recurse(depth - 1, current);

                return x;
            }

            unittest {
                assert(recurse(seed(1), null) == 1);
            }
        });
    }
}

// A delegate created early, held in a variable across unrelated statements,
// and called twice afterward -- "stored and called later" rather than
// invoked immediately where it is created.
static foreach (backend; Matrix!()) {
    @("delegate.storedThenCalledAfterUnrelatedWork." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int makeAndUseCounter(int seed) {
                int total = seed;

                int increment() {
                    total += 1;
                    return total;
                }

                int delegate() counter = &increment;

                int unrelated = seed * 2;

                auto first = counter();
                auto second = counter();

                return first + second + unrelated;
            }

            unittest {
                assert(makeAndUseCounter(10) == 43);
            }
        });
    }
}

// A lambda (`FuncExp`, not a named nested function) captures a local and is
// passed as a VALUE into another function that invokes it -- `applyTwice`
// is itself nested inside `addCaptured` so its own activation inherits
// `captured` through the same boxed `locals.dup` chain the lambda's own
// call later reads through; a lambda invoked from a call chain that never
// passes back through an activation carrying its captured local is a
// pre-existing, unrelated gap (boxed `locals.dup` copies whatever the
// CALLING activation currently holds, not a snapshot taken when the
// delegate value itself was created) and not what this fixture tests.
// `Bytecode` refuses a delegate-typed PARAMETER; a delegate-typed
// LOCAL/field works there today (see delegate.nestedCallUsesCapturedValue
// above), so only the parameter form is out.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.refusal,
        "Unsupported type in bytecode core: int delegate(int)"),
)) {
    @("lambda.passedToNestedFunctionSeesCapturedContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int addCaptured(int seed) {
                int captured = seed + 1;

                int applyTwice(int delegate(int) f) {
                    return f(f(seed));
                }

                auto lambda = (int value) => value + captured;

                return applyTwice(lambda);
            }

            unittest {
                assert(addCaptured(10) == 32);
            }
        });
    }
}

// `int[]` is not `place_value.isPlaceComposable` (its elements live behind
// a stored pointer, not inline), so a nested function capturing one gets no
// verified reference-slot shadow for it -- `bindCapturedReferenceSlots`
// still fills the slot's address (nothing about the ADDRESS depends on the
// captured type's shape), but `assertReferenceBind` declines the
// verification for it, exactly as it already does for a non-composing
// `ref` parameter. Boxed authority is what this fixture actually checks:
// the capture keeps working (read, appended to, and read again through the
// nested function) whether or not the shadow can verify it.
static foreach (backend; Matrix!()) {
    @("function.nestedFunctionCapturesNonComposingArrayDeclinesShadowSilently." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int sumWithNested(int seed) {
                int[] captured = [seed, seed + 1, seed + 2];

                int total() {
                    int result = 0;
                    foreach (value; captured)
                        result += value;
                    return result;
                }

                captured ~= seed + 3;

                return total();
            }

            unittest {
                assert(sumWithNested(1) == 1 + 2 + 3 + 4);
            }
        });
    }
}


/++
    Casts involving slices, pointers, arrays, and bool.
+/
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

// A pointer local reassigned twice within the same activation, each
// assignment a genuine host address (`values.ptr`, not `&scalar` -- see the
// carrier fixture below), exercises `impl.d`'s verified frame mirror on its
// ACCEPT path twice: `setLocal`/`mirrorToFrame` writes the new address into
// the frame slot, and the next read's `assertFrameMirror` recomposes it
// through the identical `place_value.writeValue` and compares raw bytes
// (`ai/plans/value.md` "Remaining work" item 5, the pointer leaf). A wrong
// scan policy or an asymmetric write/verify guard would surface here as an
// `AssertError` from inside the interpreter, not a wrong return value.
static foreach (backend; Matrix!()) {
    @("pointer.mirroredAcrossReassignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int reassignPointerAcrossWrites() {
                int[] first = [10, 20];
                int[] second = [30, 40, 50];

                int* p = first.ptr;
                const a = *p;

                p = second.ptr + 1;
                const b = *p;

                return a + b;
            }

            unittest {
                assert(reassignPointerAcrossWrites() == 50);
            }
        });
    }
}

// `&x` for a scalar local boxes as `isLocalPointer` (an allocation-id
// carrier), not a host address -- `place_value.writeValue`'s pointer arm
// refuses to store one, so `p`'s own frame slot must be left unmirrored on
// both the write side (`mirrorToFrame`) and the read side
// (`assertFrameMirror`), both gated by the identical `placeShapeMatches`
// check. Reading `p` (and through it, `x`'s live updates) repeatedly must
// still work correctly and never throw or assert -- the mirror's decline is
// silent, authority stays with the boxed value regardless.
static foreach (backend; Matrix!()) {
    @("pointer.localAddressCarrierDoesNotMirror." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int localAddressPointerTracksLiveUpdates() {
                int x = 10;
                int* p = &x;

                x = 20;
                const first = *p;

                x = 30;
                const second = *p;

                return first + second;
            }

            unittest {
                assert(localAddressPointerTracksLiveUpdates() == 50);
            }
        });
    }
}

// A pointer PARAMETER rebound to a fresh, per-activation array's own
// `.ptr` at every recursive depth: each activation gets its own frame slot
// (`frame_layout.computeFrameLayout`, one per activation) and its own
// mirrored address, so a stale sibling activation's address must never
// leak into another's read -- proving the per-activation frame, not a
// single shared slot, is what the mirror actually verifies against.
static foreach (backend; Matrix!()) {
    @("pointer.reboundAcrossActivations." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int recurseReboundPointer(int depth) {
                int[] values = [depth * 10, depth * 10 + 1];
                int* p = values.ptr;

                if (depth == 0)
                    return *p;

                return *p + recurseReboundPointer(depth - 1);
            }

            unittest {
                assert(recurseReboundPointer(2) == 30);
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "no byte-level memory model for floating-point locals; " ~
        "permanently refuses cast(uint*)&floatLocal"),
)) {
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
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "same as float/uint* above: no byte-level memory model for " ~
        "floating-point locals"),
)) {
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

// A same-sized struct pointer cast over an address-taken scalar reads the
// scalar's native bytes as the struct's field. SystemLinker is the oracle;
// Ctfe and LLVMJit are omitted because address-of-local reinterpretation is
// unsupported/unconfirmed there.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("pointer.scalarBitsThroughStructPointerAreRawBits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int value;
            }

            int fortyTwo() {
                return 42;
            }

            unittest {
                int value = fortyTwo;
                S* pointer = cast(S*) &value;
                assert(pointer.value == 42);
            }
        });
    }
}

// Reinterpret-WRITE (not read) through a same-size pointer cast: writing raw
// bits into a `float` local via a `uint*` must be visible to a subsequent
// direct read of the local. SystemLinker is the oracle; LLVMJit and Ctfe are
// omitted per the omit-don't-pin convention (address-of-a-local and float
// byte-reinterpretation are unconfirmed/unsupported there).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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
// SystemLinker is the oracle; Ctfe and LLVMJit remain omitted for the same
// reasons as the fixture above.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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

// Once `&f` promotes an authoritative native-scalar cell,
// a later DIRECT reassignment (`f = threePointZero`, not a pointer write)
// must keep that cell current too: both the direct read of `f` and a read
// through the pointer must see the new value's bits, not the stale ones from
// before the reassignment. SystemLinker is the oracle; other backends
// omitted per the omit-don't-pin convention (address-of-a-local is
// unconfirmed/unsupported there).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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
// call-site frontier: a freshly promoted native cell for
// the `ref` parameter must stay connected to the caller's own cell/box.
// SystemLinker is the oracle; Bytecode runs this confirmed typed-frame path.
// Other backends remain omitted per the omit-don't-pin convention
// (address-of-a-local/parameter and float byte-reinterpretation are
// unconfirmed/unsupported there).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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

// A fresh `DeclarationExp` binding is a
// new stack slot, but the interpreter never dropped a stale `scalarCells`
// entry inherited for the same `VarDeclaration`. Recursion reuses the same
// AST `VarDeclaration` for `x` at every call depth, and `child.scalarCells =
// scalarCells.dup` hands the inner frame the outer frame's already-promoted
// cell, so `int x = depth;` at depth 0 resurrected depth 1's cell instead of
// getting a fresh one. SystemLinker is the oracle; other backends omitted
// per the omit-don't-pin convention (address-of-a-local is
// unconfirmed/unsupported there).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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

// The same stale scalar-cell bug as the recursion case above, loop-shaped: a `foreach` body re-executes the same
// `DeclarationExp` for `x` every iteration, so the first iteration's
// promoted cell must not leak into the second iteration's fresh `x`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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

// Post-increment's `VarExp` arm read
// `variable in locals` directly, bypassing a promoted `scalarCells` entry --
// stale once a cross-frame pointer write (`setToFive`) refreshes only the
// cell.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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

// `(*p)++` reads and writes through
// `localPointerTarget`/`writePointerTarget`'s local-pointer arm, which only
// consulted the boxed `locals` mirror -- the same bypass post-increment's
// `VarExp` arm had, but for the pointer-deref path.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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

// `writeLocation`'s `PtrExp` cell arm
// required the pointee to be exactly the cell's own width, throwing for a
// narrower native-scalar pointee (a `ubyte*` reinterpret of a `uint`)
// instead of writing into the low bytes the way the read side
// already narrows by slicing.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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

// `&g` on a dataseg variable (module-
// level/`__gshared`/`static`) routed through `promoteScalarCell`, which
// seeded the cell from `defaultValue` (0) because a dataseg variable's real
// initializer is materialized lazily on first read, and the `VarExp` read
// arm consulted the cell before that fallback -- so taking `gValue`'s
// address made every later read of `gValue` see 0 instead of 42. Only true
// stack locals get cells; dataseg variables keep their own
// storage/initializer/extern machinery.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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

// Module-level guest state (`VarDeclaration.isDataseg`) now gets the same
// verified-frame-mirror treatment true stack locals already have
// (`impl.d`'s `mirrorToFrame`/`assertFrameMirror`, routed to a
// `module_table.ModuleTable` block instead of a frame slot, since a dataseg
// local owns no frame slot at all). Authority is still boxed `locals`; the
// four fixtures below exercise the mirror's own contract rather than any
// new guest-visible behaviour -- a wiring bug here surfaces as a hard
// `assert` failure inside the Interpreter's own execution, not a wrong
// displayed value, so `SystemLinker` agreement is still the pass bar.
//
// A scalar and a struct `__gshared` global, each mutated across several
// separate calls -- every intervening read re-verifies the mirror against
// the just-written boxed value. `Ctfe` cannot read or write dataseg storage
// at all (compile-time execution has no such storage to access); `Bytecode`
// does not yet support a struct-typed dataseg variable.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write dataseg (__gshared/static) storage"),
    Omit!(Bytecode, Because.refusal,
        "Unsupported variable in bytecode core: quickbiteDatasegPoint"),
)) {
    @("dataseg.moduleScalarAndStructMirroredAcrossWrites." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }

            __gshared int quickbiteDatasegCounter;
            __gshared Point quickbiteDatasegPoint;

            void bump() {
                quickbiteDatasegCounter = quickbiteDatasegCounter + 1;
            }

            void movePoint(int dx, int dy) {
                quickbiteDatasegPoint.x = quickbiteDatasegPoint.x + dx;
                quickbiteDatasegPoint.y = quickbiteDatasegPoint.y + dy;
            }

            unittest {
                bump();
                bump();
                bump();
                assert(quickbiteDatasegCounter == 3);

                movePoint(1, 2);
                movePoint(3, 4);
                assert(quickbiteDatasegPoint.x == 4);
                assert(quickbiteDatasegPoint.y == 6);
            }
        });
    }
}

// A heap struct's own constructor runs on a CHILD `Walker` (`impl.d`'s
// `runNewStructPointerExpression`), and a dataseg write it performs lands
// in the ONE shared `module_table.ModuleTable` block every frame resolves
// through -- so the caller must write the child's boxed dataseg values
// back (`writeBackGlobals`) exactly as an ordinary call does, or its own
// boxed copy stays at the pre-call value while the shared mirror already
// holds the constructor's, and the caller's next read of the global
// asserts on the divergence instead of merely answering staler. `Ctfe`
// cannot read or write dataseg storage at all (compile-time execution has
// no such storage to access).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write dataseg (__gshared/static) storage"),
)) {
    @("dataseg.heapStructConstructorGlobalWriteVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            __gshared int quickbiteDatasegCtorWrite;

            struct S {
                this(int _) {
                    quickbiteDatasegCtorWrite = 7;
                }
            }

            unittest {
                quickbiteDatasegCtorWrite = 1;

                auto p = new S(0);

                assert(quickbiteDatasegCtorWrite == 7);
            }
        });
    }
}

// The class sibling of the fixture above: a class constructor runs on a
// child `Walker` too (`impl.d`'s `runNewClassExpression`), sharing the same
// one `module_table.ModuleTable` block, so its dataseg write must reach the
// caller's boxed copy by the identical write-back. `Ctfe` cannot read or
// write dataseg storage at all (compile-time execution has no such storage
// to access).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write dataseg (__gshared/static) storage"),
)) {
    @("dataseg.classConstructorGlobalWriteVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            __gshared int quickbiteDatasegClassCtorWrite;

            class K {
                this(int _) {
                    quickbiteDatasegClassCtorWrite = 7;
                }
            }

            unittest {
                quickbiteDatasegClassCtorWrite = 1;

                auto k = new K(0);

                assert(quickbiteDatasegClassCtorWrite == 7);
            }
        });
    }
}

// The same `__gshared` global read from two different call frames (the
// top-level unittest body's own root frame, and a called function's own
// forked child frame) resolves to ONE mirror block -- `impl.d`'s
// `moduleTable` field is allocated once per root `Walker` and shared by
// pointer into every forked child, exactly like `classObjectTable`. Were a
// child frame to instead lazily allocate its OWN (fresh, zeroed) block the
// first time it read `quickbiteDatasegSharedAcrossFrames`, the very first
// call to `readSharedGlobal` below would already disagree with the boxed
// value it was handed (7, not 0) and the interpreter's own mirror assert
// would fire. `Ctfe` cannot read or write dataseg storage at all
// (compile-time execution has no such storage to access).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write dataseg (__gshared/static) storage"),
)) {
    @("dataseg.sameGlobalFromTwoFramesResolvesToOneBlock." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            __gshared int quickbiteDatasegSharedAcrossFrames = 7;

            int readSharedGlobal() {
                return quickbiteDatasegSharedAcrossFrames;
            }

            unittest {
                assert(quickbiteDatasegSharedAcrossFrames == 7);
                assert(readSharedGlobal() == 7);

                quickbiteDatasegSharedAcrossFrames = 21;
                assert(readSharedGlobal() == 21);
            }
        });
    }
}

// A `__gshared` global whose initializer is a function call is materialized
// lazily on its first read (`impl.d`'s `isDataseg && variable._init !is
// null` arm), not at frame-fork time -- `module_table.ModuleTable` only
// ever allocates a variable's block from inside `setLocal`'s own
// `mirrorToFrame` call, which runs after that lazy initializer has already
// produced a real value, never before. Reading it for the first time from
// inside a CALLED function (not the top-level unittest body itself) proves
// the child frame observes the same materialized value, not a
// pre-mirrored default. `Ctfe` cannot read or write dataseg storage at all
// (compile-time execution has no such storage to access).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write dataseg (__gshared/static) storage"),
)) {
    @("dataseg.lazilyMaterializedGlobalNotMirroredBeforeMaterialization." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int computeInit() {
                return 5 * 2 + 1;
            }

            __gshared int quickbiteDatasegLazyInit = computeInit();

            int readLazyGlobal() {
                return quickbiteDatasegLazyInit;
            }

            unittest {
                assert(readLazyGlobal() == 11);
            }
        });
    }
}

// A `__gshared` struct whose own type the mirror codec refuses -- a
// dynamic-array field makes `place_value.isPlaceComposable` answer `false`
// for the whole struct (a slice is not itself composable; see its own
// header comment) -- declines on BOTH `mirrorToFrame` and `assertFrameMirror`
// identically, via their shared `isPlaceComposable` gate, so this global
// never enters the mirror at all and keeps using the existing boxed
// `locals` path exclusively. `Ctfe` cannot read or write dataseg storage at
// all (compile-time execution has no such storage to access); `Bytecode`
// does not yet support a dynamic-array field access on a dataseg struct.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write dataseg (__gshared/static) storage"),
    Omit!(Bytecode, Because.refusal,
        "Unsupported dynamic array access in bytecode core: " ~
        "quickbiteDatasegWithArray.data"),
)) {
    @("dataseg.mirrorRefusedShapeDeclinesOnBothSides." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct WithArray { int[] data; }

            __gshared WithArray quickbiteDatasegWithArray;

            void appendOne() {
                quickbiteDatasegWithArray.data =
                    quickbiteDatasegWithArray.data ~ 1;
            }

            unittest {
                appendOne();
                appendOne();
                assert(quickbiteDatasegWithArray.data.length == 2);
                assert(quickbiteDatasegWithArray.data[0] == 1);
                assert(quickbiteDatasegWithArray.data[1] == 1);
            }
        });
    }
}

// Once `&i` has promoted a native-scalar
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
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.diverges,
        "see Interpreter pin below (throws loudly instead of writing " ~
        "memory)"),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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

// Array-native-storage guest call site: `&a[0]` takes a
// pointer into a dynamic array local, then the array is written DIRECTLY
// (`a[0] = ...`, not through the pointer). SystemLinker's `p` aliases `a`'s
// real storage, so the direct write is visible through `*p`.
static foreach (backend; Matrix!()) {
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

// The static-array-local sibling of the fixture above: `&a[0]` into a
// plain LOCAL static array (`int[3] a;`, not a struct/class field, and not
// a dynamic array), then a direct element write. `promoteArrayCell` (the
// eager `arrayCells` promotion `arrayPointer` calls at address-of time)
// guards on `isDynamicArrayType`, so a static array local never gets an
// `arrayCells` entry at all -- unlike the dynamic-array case above, none of
// `runPointerExpression`'s `*cellValue` checks can ever fire for it. Its
// pointer is still array-allocation-backed (minted via `allocationId`, the
// same mechanism the dynamic-array case uses), so `arrayPointerVariable`
// still resolves it back to `a` -- but the dereference fallback returned
// the STALE boxed snapshot taken at address-of time instead of re-reading
// `locals`, so a later direct write was invisible through the earlier
// pointer. SystemLinker's `p` aliases `a`'s real storage, so the direct
// write is visible through `*p`. Other backends omitted per the
// omit-don't-pin convention (unconfirmed there).
static foreach (backend; Matrix!()) {
    @("pointer.staticArrayLocalElementWrittenDirectlyIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                int[3] a;
                a[0] = one();
                int* p = &a[0];
                a[0] = ninetyNine();
                assert(*p == 99);
            }
        });
    }
}

// Write-side counterpart of the fixture above: a write
// THROUGH one pointer into a dynamic array element must be visible through a
// SECOND, independently-taken pointer into the same element. SystemLinker's
// `p`/`q` both alias `a`'s real storage, so a write through `p` is visible
// through `q`.
static foreach (backend; Matrix!()) {
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

// `foreach (ref e; a)` mutation must be
// visible through an earlier-taken pointer into `a`. SystemLinker's `p`
// aliases `a`'s real storage, so the loop's writes are visible through `*p`.
// The mature backend matrix now confirms the same aliasing behavior.
static foreach (backend; Matrix!()) {
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

// A compound/post-increment write THROUGH an
// array-element pointer (`(*p)++`) must be visible both through the pointer
// itself and directly on the array. SystemLinker's `p` aliases `a`'s real
// storage, so the increment is visible both ways. The mature backend matrix
// now confirms the same aliasing behavior.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "post-increment through an array-element pointer expects a native pointer representation"),
)) {
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

// Cross-frame array-pointer aliasing: a callee
// takes `&a[i]` of a caller's array passed by `ref` and writes through it.
// SystemLinker's `ref` parameter aliases the caller's real storage, so `p`
// (taken in the caller BEFORE the call, into the SAME backing array) must
// see the write too. The mature backend matrix now confirms the same
// cross-frame aliasing behavior.
static foreach (backend; Matrix!()) {
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

// A pointer taken into a SLICE (not the source
// array itself) must still see a later direct write to the source. This is
// a genuine characterization test, not a gap fixture: `promoteSliceArrayCell`
// already gives a slice local an `arrayCells` entry sharing the SAME
// `NativeArray` bytes as its root source's own cell (`promoteArrayCell`
// keyed by the slice-alias-resolved root, exactly as `arrayPointer`'s own
// `&a[i]` resolution already does), so `&s[1]` promotes/reads that shared
// cell directly -- confirmed green on Interpreter with no production change
// alongside this fixture. SystemLinker's `p` aliases `a`'s real storage, so
// the direct write is visible through `*p`. The mature backend matrix now
// confirms the same aliasing behavior.
static foreach (backend; Matrix!()) {
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

// Struct phase, first guest call site: `&s.x` snapshotted
// the field's value at address-of time instead of aliasing `s`'s own
// storage, so a later direct write to the field (`s.x = ninetyNine()`) was
// invisible through the earlier pointer -- the same snapshot gap the array
// phase closed for `&a[i]`. SystemLinker's `p` aliases `s`'s real storage, so
// the direct write is visible through `*p`. The mature backend matrix now
// confirms the same aliasing behavior.
static foreach (backend; Matrix!()) {
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

// Class sibling of the struct fixture above: a class object's scalar
// field, address-taken via `&c.x`, must
// alias the SAME storage a later direct field write updates. Other backends
// omitted per the omit-don't-pin convention (unconfirmed there), matching
// the struct fixture's own backend set.
static foreach (backend; Matrix!()) {
    @("pointer.classFieldWrittenDirectlyIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
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
                C c = new C();
                c.x = one();
                c.y = two();
                int* p = &c.x;
                c.x = ninetyNine();
                assert(*p == 99);
            }
        });
    }
}

// Write-through-pointer sibling of the direct-write fixture above: the
// same `&c.x` cell must also accept a
// write THROUGH the pointer (`*p = v`), visible via a later direct field
// read, mirroring the struct phase's own
// `pointer.addressOfStructFieldWriteThroughUpdatesField`. Other backends
// omitted per the omit-don't-pin convention, matching the direct-write class
// fixture's own backend set.
static foreach (backend; Matrix!()) {
    @("pointer.classFieldWriteThroughPointerUpdatesField." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
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
                C c = new C();
                c.x = one();
                c.y = two();
                int* p = &c.x;
                *p = ninetyNine();
                assert(c.x == 99);
            }
        });
    }
}

// Cross-frame sibling of the write-through fixture above: the caller
// takes `&c.x` (promoting a `classCells`
// entry and a `classFieldPointerVariables`/`classFieldPointerFieldIndices`
// reverse-lookup entry in the CALLER's own frame), then passes the pointer
// into a callee that writes through it, mirroring the struct phase's own
// `pointer.structFieldWriteThroughPointerInCalleeIsVisibleToCaller`. Other
// backends omitted per the omit-don't-pin convention, matching the other
// class fixtures' own backend set.
static foreach (backend; Matrix!()) {
    @("pointer.classFieldWriteThroughPointerInCalleeIsVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
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
                C c = new C();
                c.x = one();
                c.y = two();
                int* p = &c.x;
                put(p, ninetyNine());
                return *p + c.x;
            }

            unittest {
                assert(f() == 198);
            }
        });
    }
}

// Same-frame plain-variable class aliasing: `C c2 = c;` copies a
// REFERENCE, not an object, so
// `c` and `c2` must observe the same underlying object -- a write through
// one alias's field must be visible through the other, with no `&`/pointer
// involved at all. Before this slice each class-typed local boxed its own
// independent copy of the field array (`Value.withClassField` writes only
// into the target variable's own `locals` entry), so the interpreter
// silently dropped the write. Only Interpreter and SystemLinker (the
// oracle) are pinned here per the omit-don't-pin convention; the other
// backends are untouched by this slice.
static foreach (backend; Matrix!()) {
    @("class.aliasedVariableWriteIsVisibleThroughOriginal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                C c = new C();
                C c2 = c;
                c2.x = ninetyNine();
                assert(c.x == 99);
            }
        });
    }
}

// Same-frame plain-variable class aliasing, non-scalar field:
// `classCellFieldValue` -- the DIRECT (non-pointer) class-field
// read's authoritative-cell dispatcher -- only consults the shared
// `classCells` cell for a `native_scalar.isNativeScalarType` field; a
// scalar-element static-array field still falls back to the boxed `locals`
// mirror, which the OTHER alias's write never touches. `c2.arr[0] = 99;`
// already reaches the shared cell (the write side's
// `writeClassCellScalarFields` widens every scalar-element static-array
// field), but reading `c.arr[0]` back through the ORIGINAL
// alias, with no `&`/pointer involved, still sees the stale independent copy.
// Only Interpreter and SystemLinker (the oracle) are pinned here per the
// omit-don't-pin convention.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws its own unrelated \"Unsupported assignment in bytecode core: c2.arr[0] = ninetyNine()\" for this shape, not a wrong value"),
)) {
    @("class.aliasedVariableArrayFieldWriteIsVisibleThroughOriginal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int[2] arr;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                C c = new C();
                C c2 = c;
                c2.arr[0] = ninetyNine();
                assert(c.arr[0] == 99);
            }
        });
    }
}

// Same-frame plain-variable class aliasing, struct-typed field:
// `classCellFieldValue` -- the DIRECT (non-pointer)
// class-field read's authoritative-cell dispatcher -- widened the scalar and
// scalar-element-static-array field shapes so far; a struct-typed field
// still falls back to the boxed `locals` mirror, which the OTHER alias's
// write never touches. `c2.inner.x = 99;` already reaches the shared cell
// (the write side's `writeClassCellScalarFields` already recurses one level
// into a struct-typed field), but
// reading `c.inner.x` back through the ORIGINAL alias, with no `&`/pointer
// involved, still sees the stale independent copy. Only Interpreter and
// SystemLinker (the oracle) are pinned here per the omit-don't-pin
// convention.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws its own unrelated \"Unsupported type in bytecode core: Inner\" for this shape, not a wrong value"),
)) {
    @("class.aliasedVariableStructFieldWriteIsVisibleThroughOriginal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            class C {
                Inner inner;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                C c = new C();
                C c2 = c;
                c2.inner.x = ninetyNine();
                assert(c.inner.x == 99);
            }
        });
    }
}

// Cross-frame class reference aliasing: passing the SAME object as TWO
// different by-value
// parameters must leave both parameters observing the SAME object, since a
// class argument is reference-passed -- exactly as if both parameters were
// `C c2 = c;` aliases of one another, except the aliasing happens at the
// call boundary (parameter binding) rather than a declaration. Both
// parameters must share the caller's authoritative class cell during the
// call; post-call value diffing cannot establish that identity.
static foreach (backend; Matrix!()) {
    @("class.sameObjectPassedAsTwoParametersSharesIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;
            }

            void combine(C a, C b) {
                b.x = 99;
                assert(a.x == 99);
            }

            unittest {
                C c = new C();
                combine(c, c);
            }
        });
    }
}

// A class object passed unchanged through recursive calls keeps one
// identity across every activation: a recursive function's own class
// parameter gets its OWN frame slot at each recursion depth, but every
// depth's slot must still resolve to the SAME object body. Mutating a
// field at the deepest call and reading it back, unmutated, through every
// ancestor frame's own parameter on the way back out proves the shared
// identity rather than merely a shared final value.
static foreach (backend; Matrix!()) {
    @("class.recursiveCallSharesObjectIdentityAcrossActivations." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;
            }

            int rec(C c, int depth) {
                if (depth == 0) {
                    c.x = 42;
                    return c.x;
                }
                const inner = rec(c, depth - 1);
                return c.x + inner;
            }

            unittest {
                auto c = new C();
                assert(rec(c, 3) == 168);
            }
        });
    }
}

// A class object reached through a class-typed field keeps one identity when
// copied into a local. Promoting storage through the local must therefore make
// the write visible through the original field reference too.
static foreach (backend; Matrix!()) {
    @("class.fieldObjectCopiedToLocalSharesAuthoritativeStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int x;
            }

            class Parent {
                Child child;
            }

            unittest {
                Parent parent = new Parent();
                parent.child = new Child();
                Child child = parent.child;
                int* pointer = &child.x;
                *pointer = 99;
                assert(parent.child.x == 99);
            }
        });
    }
}

// A class field whose own type is a class -- an object GRAPH, not only a
// single object -- built as a short linked list, then mutated and read back
// through the SAME chain of field accesses throughout: this is the
// real-object-graph shape the native frame mirror's class-body composition
// now has to compose and verify without asserting. Deliberately built and
// read through one root reference only (`first.next...`), never through a
// second, independent local bound to an interior node: `ai/plans/value.md`'s
// Cell coherence contract already names class-typed fields as having "no
// cell support on either the read or write side", and a second alias into
// the middle of the graph is exactly the shape that gap affects -- out of
// this fixture's scope, which is the mirror's own composition, not that
// pre-existing boxed-authority limit.
static foreach (backend; Matrix!()) {
    @("class.linkedListNodeMutationVisibleThroughChain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Node {
                int value;
                Node next;
            }

            int mark(int seed) {
                return seed * 5 + 2;
            }

            unittest {
                auto first = new Node();
                first.value = mark(1);
                first.next = new Node();
                first.next.value = mark(2);
                first.next.next = new Node();
                first.next.next.value = mark(3);

                assert(first.value == mark(1));
                assert(first.next.value == mark(2));
                assert(first.next.next.value == mark(3));

                first.next.next.value = mark(30);

                assert(first.next.next.value == mark(30));
                assert(first.next.value == mark(2));
                assert(first.value == mark(1));
            }
        });
    }
}

// A class object referencing ITSELF (`n.next = n`) must not crash the
// interpreter: `impl.d`'s `classBodyShapeMatches` (the shared pure gate
// `mirrorClassToFrame`/`assertClassFrameMirror` both call before either ever
// reaches `place_value.writeClassBody`) now seeds its own `visiting` set
// with the ROOT object's identity before walking its fields, so a field
// that reintroduces that same identity one level down declines the mirror
// right there, deterministically, instead of reaching `writeClassBody`'s
// own address-keyed cycle guard and throwing out into this assignment.
static foreach (backend; Matrix!()) {
    @("class.selfReferencingObjectDoesNotCrash." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Node {
                int value;
                Node next;
            }

            int mark(int seed) {
                return seed * 11 + 7;
            }

            unittest {
                auto n = new Node();
                n.value = mark(1);
                n.next = n;

                assert(n.next.value == mark(1));
            }
        });
    }
}

// The two-object counterpart of the self-reference fixture above: a ring
// (`a.next = b; b.next = a;`) reintroduces `a`'s own identity through `b`'s
// field, one level further down than the direct self-reference does. The
// same seeded `visiting` set in `classBodyShapeMatches` catches this shape
// too, since the reintroduced identity is checked against the ROOT's own
// seed no matter how many field hops away it resurfaces.
static foreach (backend; Matrix!()) {
    @("class.twoNodeRingDoesNotCrash." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Node {
                int value;
                Node next;
            }

            int mark(int seed) {
                return seed * 11 + 7;
            }

            unittest {
                auto a = new Node();
                auto b = new Node();

                a.value = mark(1);
                b.value = mark(2);

                a.next = b;
                b.next = a;

                assert(a.next.value == mark(2));
                assert(b.next.value == mark(1));
            }
        });
    }
}

// A shared object graph's nested body, rewritten through a DIFFERENT
// binding's own mirror after `parent`'s own mirror last established, must
// not crash a later read of `parent`: `child`'s own `mirrorClassToFrame`
// write (`child.x = 5;`) rewrites the SAME `object_table.ObjectTable`-owned
// body `parent`'s established graph already composed (`parent.child` is the
// identical identity), strictly AFTER `parent`'s own mirror recorded what
// it wrote. The pre-existing boxed-authority gap
// (`ai/plans/value.md`'s Cell coherence "Known gaps") already means
// `parent`'s own boxed `locals[]` copy of `child`'s field goes stale here --
// a wrong VALUE on a correct guest program, on master too -- but the native
// mirror's own verify step must not turn that pre-existing wrong answer
// into an internal `AssertError` crash.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.diverges,
        "boxed `locals[]` staleness (ai/plans/value.md's Cell coherence " ~
        "Known gaps): child's own mirror write refreshes the shared " ~
        "object body, but parent's boxed copy of the child field is never " ~
        "refreshed, so parent.child.x reads back stale"),
)) {
    @("class.sharedNestedBodyRewrittenBySiblingBindingDoesNotCrash." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int x;
            }

            class Parent {
                Child child;
            }

            unittest {
                auto child = new Child();
                auto parent = new Parent();
                parent.child = child;

                child.x = 5;

                assert(parent.child.x == 5);
            }
        });
    }
}

// The `Because.diverges` pin the fixture above owes, and the only place its
// own "does not crash" property is actually executed on the backend that has
// the mirror: Interpreter runs the guest program to completion and fails its
// OWN `assert(parent.child.x == 5)` with the stale boxed value, rather than
// dying inside the interpreter with a mirror-verify `AssertError`. Hand-
// listed because no `SystemLinker`-oracle expectation applies to it
// (`SystemLinker` passes).
static foreach (backend; AliasSeq!(Interpreter)) {
    @("class.sharedNestedBodyRewrittenBySiblingBindingReadsStale." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int x;
            }

            class Parent {
                Child child;
            }

            unittest {
                auto child = new Child();
                auto parent = new Parent();
                parent.child = child;

                child.x = 5;

                assert(parent.child.x == 5);
            }
        }).shouldThrowWithMessage("0 != 5");
    }
}

// The `DotVarExp`-alias counterpart of the fixture above: `c` aliases
// `parent.child`'s own identity through a non-`VarExp` source, so it gets no
// promoted cell of its own (`classIdentityAliasedByAnotherBinding`'s own
// header comment) and establishes an INDEPENDENT mirror for the same
// identity. Writing through `c` rewrites the shared body strictly after
// `parent`'s own mirror last established, the identical shape the fixture
// above exercises through a plain top-level variable instead of an alias.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.diverges,
        "boxed `locals[]` staleness (ai/plans/value.md's Cell coherence " ~
        "Known gaps): c's own mirror write refreshes the shared object " ~
        "body, but parent's boxed copy of the child field is never " ~
        "refreshed, so parent.child.x reads back stale"),
)) {
    @("class.sharedNestedBodyRewrittenByDotVarAliasDoesNotCrash." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int x;
            }

            class Parent {
                Child child;
            }

            unittest {
                auto parent = new Parent();
                parent.child = new Child();

                Child c = parent.child;
                c.x = 7;

                assert(parent.child.x == 7);
            }
        });
    }
}

// The `Because.diverges` pin the alias fixture above owes, and the only
// place its own "does not crash" property is executed on the backend that
// has the mirror: the same stale boxed read, reached through the alias
// instead of a plain top-level variable.
static foreach (backend; AliasSeq!(Interpreter)) {
    @("class.sharedNestedBodyRewrittenByDotVarAliasReadsStale." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int x;
            }

            class Parent {
                Child child;
            }

            unittest {
                auto parent = new Parent();
                parent.child = new Child();

                Child c = parent.child;
                c.x = 7;

                assert(parent.child.x == 7);
            }
        }).shouldThrowWithMessage("0 != 7");
    }
}

// One object reachable twice from ONE composed graph -- a DAG, not a cycle:
// both of `parent`'s own class-typed fields reference the identical `Child`
// identity. Writing through one field (`parent.left.x = 5`) refreshes the
// shared `object_table.ObjectTable` body, but leaves the OTHER field's own
// boxed snapshot inside `parent`'s `locals[]` copy stale -- the same
// pre-existing boxed-authority gap the fixtures above exercise across
// bindings, here reached entirely within a single value. The two snapshots
// then genuinely contradict each other, so a mirror that writes the shared
// body once per sibling (last snapshot wins) and verifies each sibling
// against its own snapshot must decline the shape outright rather than
// turn that contradiction into an internal `AssertError`.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.diverges,
        "boxed `locals[]` staleness (ai/plans/value.md's Cell coherence " ~
        "Known gaps): the write through parent.left refreshes the shared " ~
        "object body, but parent's own boxed copy of the right field is " ~
        "never refreshed, so parent.right.x reads back stale"),
)) {
    @("class.sharedSiblingFieldsWithDifferentSnapshotsDoesNotCrash." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int x;
            }

            class Parent {
                Child left;
                Child right;
            }

            unittest {
                auto parent = new Parent();
                parent.left = new Child();
                parent.right = parent.left;

                parent.left.x = 5;

                assert(parent.right.x == 5);
            }
        });
    }
}

// The `Because.diverges` pin the shared-sibling fixture above owes, and the
// only place its own "does not crash" property is executed on the backend
// that has the mirror: Interpreter runs the guest program to completion and
// fails its OWN assertion with the stale boxed value rather than dying
// inside the interpreter with a mirror-verify `AssertError`. Hand-listed
// because no `SystemLinker`-oracle expectation applies to it
// (`SystemLinker` passes).
static foreach (backend; AliasSeq!(Interpreter)) {
    @("class.sharedSiblingFieldsWithDifferentSnapshotsReadsStale." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int x;
            }

            class Parent {
                Child left;
                Child right;
            }

            unittest {
                auto parent = new Parent();
                parent.left = new Child();
                parent.right = parent.left;

                parent.left.x = 5;

                assert(parent.right.x == 5);
            }
        }).shouldThrowWithMessage("0 != 5");
    }
}

// The cross-activation counterpart: a callee's own parameter mirror
// (`bump`'s own `c`) rewrites the shared body strictly after the caller's
// `parent` established its own mirror -- the callee's per-walker
// `mirrorEstablished`/generation bookkeeping is a SEPARATE frame's
// own, but `object_table.ObjectTable` is shared across every activation for
// the whole execution (`impl.d`'s `classObjectTable` field comment), so the
// rewrite is visible the moment control returns to the caller.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.diverges,
        "boxed `locals[]` staleness (ai/plans/value.md's Cell coherence " ~
        "Known gaps): bump's own mirror write refreshes the shared object " ~
        "body, but parent's boxed copy of the child field is never " ~
        "refreshed, so parent.child.x reads back stale"),
)) {
    @("class.sharedNestedBodyRewrittenAcrossActivationDoesNotCrash." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int x;
            }

            class Parent {
                Child child;
            }

            void bump(Child c) {
                c.x = c.x + 1;
            }

            unittest {
                auto parent = new Parent();
                parent.child = new Child();
                parent.child.x = 6;

                bump(parent.child);

                assert(parent.child.x == 7);
            }
        });
    }
}

// The `Because.diverges` pin the cross-activation fixture above owes, and
// the only place its own "does not crash" property is executed on the
// backend that has the mirror: the caller's boxed copy still holds the
// pre-call 6 the callee's mirror write replaced.
static foreach (backend; AliasSeq!(Interpreter)) {
    @("class.sharedNestedBodyRewrittenAcrossActivationReadsStale." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int x;
            }

            class Parent {
                Child child;
            }

            void bump(Child c) {
                c.x = c.x + 1;
            }

            unittest {
                auto parent = new Parent();
                parent.child = new Child();
                parent.child.x = 6;

                bump(parent.child);

                assert(parent.child.x == 7);
            }
        }).shouldThrowWithMessage("6 != 7");
    }
}

// A heap struct's own constructor runs on a CHILD `Walker` (`impl.d`'s
// `runNewStructPointerExpression`), which mints its own class identities
// (`++nextClassObjectId`) for any `new` it evaluates -- the constructed
// `C` here. That counter must be merged back into the caller once the
// constructor returns, or the caller's own NEXT `new` (`new D()` below)
// re-mints the SAME identity the constructor already handed out, giving
// two live, differently-sized objects the SAME `object_table.ObjectTable`
// key. SystemLinker runs this fine (real heap addresses never collide);
// the interpreter's own `ObjectTable` throws outright the moment the two
// disagree on size, converting a pre-existing (harmless-until-now) boxed
// identity aliasing into a guest-visible crash.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed),
)) {
    @("classIdentity.structConstructorIdentityDoesNotCollideWithCallersNext." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;
            }

            class D {
                long a, b;
            }

            struct S {
                C c;

                this(int _) {
                    c = new C();
                }
            }

            unittest {
                auto s = new S(1);
                D d = new D();
                d = null;

                C e = s.c;

                assert(e.x == 0);
            }
        });
    }
}

// The exception-path sibling of the fixture above: a struct constructor
// that mints a class identity and then THROWS out of its own body must
// still merge `nextClassObjectId` back into the caller (`impl.d`'s
// `runNewStructPointerExpression`) -- unwinding through a guest exception
// the caller catches is not a different path for the counter than
// returning normally, and the collision it otherwise leaves behind makes
// `ObjectTable.storageFor` throw on the caller's next differently-sized
// `new`.
static foreach (backend; Matrix!()) {
    @("classIdentity.throwingStructConstructorIdentityDoesNotCollideWithCallersNext." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;
            }

            class D {
                long a, b;
            }

            struct S {
                int unused;

                this(int _) {
                    C c = new C();
                    c.x = 1;
                    throw new Exception("boom");
                }
            }

            unittest {
                bool caught;

                try {
                    auto s = new S(1);
                } catch (Exception) {
                    caught = true;
                }

                assert(caught);

                D d = new D();
                d.a = 2;

                assert(d.a == 2);
            }
        });
    }
}

// The class-constructor sibling of the same contract: a class constructor
// runs on its own CHILD `Walker` too (`impl.d`'s `runNewClassExpression`),
// and a guest exception unwinding out of its body is not a different path
// for `nextClassObjectId` than returning normally -- both go through
// `mergeNewClassExpressionState`. Left unmerged, the caller's next
// differently-sized `new` re-mints the identity the constructor's own `new
// C()` already handed out and `ObjectTable.storageFor` throws on the size
// disagreement.
static foreach (backend; Matrix!()) {
    @("classIdentity.throwingClassConstructorIdentityDoesNotCollideWithCallersNext." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;
            }

            class D {
                long a, b;
            }

            class Thrower {
                this(int _) {
                    C c = new C();
                    c.x = 1;
                    throw new Exception("boom");
                }
            }

            unittest {
                bool caught;

                try {
                    auto t = new Thrower(1);
                } catch (Exception) {
                    caught = true;
                }

                assert(caught);

                D d = new D();
                d.a = 2;

                assert(d.a == 2);
            }
        });
    }
}

// The destructor sibling of the same contract: a destructor that mints a
// class identity and then THROWS must still merge `nextClassObjectId` back
// into the caller. A destructor runs as an ordinary member call (`impl.d`'s
// `isDtorExpStatement` arm evaluates a plain `CallExp`), so it merges
// through `writeBackMemberFunctionState`'s existing `InterpretedException`
// path rather than through a `new`-expression site of its own -- this
// fixture pins that the scope-exit route really does share that path.
static foreach (backend; Matrix!()) {
    @("classIdentity.throwingDestructorIdentityDoesNotCollideWithCallersNext." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;
            }

            class D {
                long a, b;
            }

            struct S {
                int unused;

                ~this() {
                    C c = new C();
                    c.x = 1;
                    throw new Exception("boom");
                }
            }

            unittest {
                bool caught;

                try {
                    {
                        S s = S(0);
                    }
                } catch (Exception) {
                    caught = true;
                }

                assert(caught);

                D d = new D();
                d.a = 2;

                assert(d.a == 2);
            }
        });
    }
}

// A class-typed field reassigned to a NEW object must observe the new
// object's own fields afterward, not retain the old object's -- ordinary
// class-field reassignment (a reference rebind, `ai/plans/value.md`'s Cell
// coherence contract), which the native mirror's object-graph composition
// must not disturb.
static foreach (backend; Matrix!()) {
    @("classField.reassignedObjectFieldObservesNewObjectsFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Child {
                int value;
            }

            class Parent {
                Child child;
            }

            int mark(int seed) {
                return seed * 3 + 1;
            }

            unittest {
                auto parent = new Parent();

                parent.child = new Child();
                parent.child.value = mark(1);
                assert(parent.child.value == mark(1));

                parent.child = new Child();
                parent.child.value = mark(2);
                assert(parent.child.value == mark(2));
            }
        });
    }
}

// Two ref class parameters bound from the same plain variable denote the same
// reference slot, so taking either parameter's address must produce equal
// pointers.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve repeated ref class-argument address identity"),
)) {
    @("class.repeatedRefArgumentPreservesAddressIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int value;
            }

            void verify(ref C first, ref C second) {
                assert(&first == &second);
            }

            unittest {
                C value = new C();
                verify(value, value);
            }
        });
    }
}

// Two ref parameters bound from the same direct struct field denote one
// storage location, so taking either parameter's address must produce equal
// pointers even though the argument is not a plain variable.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve repeated struct-field ref-argument identity"),
)) {
    @("structField.repeatedRefArgumentPreservesAddressIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int value;
            }

            void verify(ref int first, ref int second) {
                assert(&first == &second);
                first = 99;
                assert(second == 99);
            }

            unittest {
                S value = S(42);
                verify(value.value, value.value);
                assert(value.value == 99);
            }
        });
    }
}

// Direct fields reached through a source struct and its plain ref alias denote
// one storage location when passed by ref.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve aliased struct-field ref-argument identity"),
)) {
    @("structField.aliasedRefArgumentsPreserveAddressIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int value;
            }

            void verify(ref int first, ref int second) {
                assert(&first == &second);
                first = 99;
                assert(second == 99);
            }

            unittest {
                S source = S(42);
                ref S alias_ = source;
                verify(source.value, alias_.value);
                assert(source.value == 99);
            }
        });
    }
}

// Two ref parameters bound from the same direct class field denote one
// storage location, just like the corresponding direct struct-field case.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve repeated class-field ref-argument identity"),
)) {
    @("classField.repeatedRefArgumentPreservesAddressIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int value;
            }

            void verify(ref int first, ref int second) {
                assert(&first == &second);
                first = 99;
                assert(second == 99);
            }

            unittest {
                C value = new C();
                value.value = 42;
                verify(value.value, value.value);
                assert(value.value == 99);
            }
        });
    }
}

// A class cell promoted by taking a field's address is authoritative for the
// whole object, not only for later field reads. Passing the class value onward
// must therefore reconstruct the argument from the cell after a pointer write,
// rather than copy the stale boxed mirror into the callee.
static foreach (backend; Matrix!()) {
    @("class.wholeValueArgumentReadsAuthoritativeCell." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;
            }

            void put(int* pointer, int value) {
                *pointer = value;
            }

            int observe(C value) {
                return value.x;
            }

            C forward(C value) {
                return value;
            }

            unittest {
                C c = new C();
                C alias_ = c;
                int* pointer = &c.x;
                put(pointer, 99);
                assert(observe(forward(alias_)) == 99);
            }
        });
    }
}

// A dynamic-array field is a slice value whose header belongs to the class
// object while its elements live in separate backing storage. Taking an
// element address and writing through it must remain visible when the whole
// field is copied and when the whole object is passed onward.
static foreach (backend; Matrix!()) {
    @("class.dynamicArrayFieldReadsAuthoritativeStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int[] values;
            }

            void put(int* pointer, int value) {
                *pointer = value;
            }

            int observe(C value) {
                int[] copy = value.values;
                return copy[0];
            }

            unittest {
                C value = new C();
                value.values = [42, 7];
                int* pointer = &value.values[0];
                put(pointer, 99);
                int[] field = value.values;
                assert(field[0] == 99);
                assert(observe(value) == 99);
            }
        });
    }
}

// A class `int[]` field: construction through an explicit constructor,
// reassignment, and reading an element and `.length` back, all driven by
// element size rather than any string special case.
static foreach (backend; Matrix!()) {
    @("classField.intArrayFieldConstructedReassignedAndIndexed." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Box {
                int[] values;

                this(int[] input) {
                    values = input;
                }
            }

            int addOne(int x) {
                return x + 1;
            }

            unittest {
                int first = addOne(9);
                int second = addOne(19);
                int third = addOne(29);
                auto box = new Box([first, second, third]);
                assert(box.values.length == 3);
                assert(box.values[1] == 20);

                int fourth = addOne(39);
                int fifth = addOne(49);
                box.values = [fourth, fifth];
                assert(box.values.length == 2);
                assert(box.values[0] == 40);
                assert(box.values[1] == 50);
            }
        });
    }
}

// The `string` sibling of the fixture above: a class `string` field must
// construct, reassign, and read the same way as any other `T[]` field.
static foreach (backend; Matrix!()) {
    @("classField.stringFieldConstructedReassignedAndIndexed." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Message {
                string text;

                this(string input) {
                    text = input;
                }
            }

            string greeting() {
                return "hi";
            }

            string farewell() {
                return "bye";
            }

            unittest {
                auto message = new Message(greeting());
                assert(message.text.length == 2);
                assert(message.text[0] == 'h');

                message.text = farewell();
                assert(message.text.length == 3);
                assert(message.text[1] == 'y');
            }
        });
    }
}

// A `dstring` (4-byte element) class field, proving the fix generalises by
// element size rather than being narrowly scoped to `char`/`string`.
static foreach (backend; Matrix!()) {
    @("classField.dstringFieldConstructedReassignedAndIndexed." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class WideMessage {
                dstring text;

                this(dstring input) {
                    text = input;
                }
            }

            dstring wideGreeting() {
                return "hi"d;
            }

            dstring wideFarewell() {
                return "bye"d;
            }

            unittest {
                auto message = new WideMessage(wideGreeting());
                assert(message.text.length == 2);
                assert(message.text[0] == 'h');

                message.text = wideFarewell();
                assert(message.text.length == 3);
                assert(message.text[1] == 'y');
            }
        });
    }
}

// A class slice field whose elements are structs keeps its element storage
// authoritative after an element field becomes addressable. Pointer and ref
// mutations must both be visible through a whole-field copy and a whole-object
// argument.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support taking the address of a class array field element"),
)) {
    @("class.structSliceFieldReadsAuthoritativeStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
            }

            class C {
                S[] values;
            }

            int observe(C value) {
                S[] copy = value.values;
                return copy[0].x;
            }

            unittest {
                C value = new C();
                value.values = [S(42)];
                int* pointer = &value.values[0].x;
                *pointer = 77;
                ref int alias_ = value.values[0].x;
                alias_ = 99;
                S[] field = value.values;
                assert(field[0].x == 99);
                assert(observe(value) == 99);
            }
        });
    }
}

// A class static-array field whose elements are structs keeps its inline
// element storage authoritative after an element field becomes addressable.
// The mutation must remain visible through whole-field and whole-object reads.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support taking the address of a class array field element"),
)) {
    @("class.structStaticArrayFieldReadsAuthoritativeStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
            }

            int fortyTwo() {
                return 42;
            }

            class C {
                S[1] values = [S(fortyTwo())];
            }

            int observe(C value) {
                S[1] copy = value.values;
                return copy[0].x;
            }

            unittest {
                C value = new C();
                int* pointer = &value.values[0].x;
                *pointer = 99;
                S[1] field = value.values;
                assert(field[0].x == 99);
                assert(observe(value) == 99);
            }
        });
    }
}

// A struct static-array field whose elements are structs keeps its inline
// element storage authoritative after an element field becomes addressable.
// The mutation must remain visible through whole-field and whole-struct reads.
static foreach (backend; Matrix!()) {
    @("struct.structStaticArrayFieldReadsAuthoritativeStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            int fortyTwo() {
                return 42;
            }

            struct Outer {
                Inner[1] values = [Inner(fortyTwo())];
            }

            int observe(Outer value) {
                Inner[1] copy = value.values;
                return copy[0].x;
            }

            unittest {
                Outer value;
                int* pointer = &value.values[0].x;
                *pointer = 99;
                Inner[1] field = value.values;
                assert(field[0].x == 99);
                assert(observe(value) == 99);
            }
        });
    }
}

// A struct slice field whose elements are structs keeps its referenced
// element storage authoritative after an element field becomes addressable.
// Pointer and ref mutations must remain visible through a whole-field copy
// and a whole-struct argument.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support taking the address of a struct array field element"),
)) {
    @("struct.structSliceFieldReadsAuthoritativeStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            int fortyTwo() {
                return 42;
            }

            struct Outer {
                Inner[] values = [Inner(fortyTwo())];
            }

            int observe(Outer value) {
                Inner[] copy = value.values;
                return copy[0].x;
            }

            unittest {
                Outer value;
                int* pointer = &value.values[0].x;
                *pointer = 77;
                ref int alias_ = value.values[0].x;
                alias_ = 99;
                Inner[] field = value.values;
                assert(field[0].x == 99);
                assert(observe(value) == 99);
            }
        });
    }
}

// A struct cell promoted through one alias is authoritative for the whole
// value reached through another alias. SystemLinker therefore observes a
// pointer write when the aliased struct is passed onward as a value.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support taking the address of a struct field"),
)) {
    @("struct.wholeValueAliasReadsAuthoritativeCell." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
            }

            void put(int* pointer, int value) {
                *pointer = value;
            }

            int observe(S value) {
                return value.x;
            }

            unittest {
                S value = S(42);
                ref S alias_ = value;
                int* pointer = &value.x;
                put(pointer, 99);
                assert(observe(alias_) == 99);
            }
        });
    }
}

// A plain ref struct local denotes the source's storage, including its
// address. SystemLinker is the oracle for the shared address identity.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve ref struct-local address identity"),
)) {
    @("pointer.structRefLocalPreservesAddressIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int value;
            }

            unittest {
                S source = S(42);
                ref S alias_ = source;
                S* pointer = &source;
                assert(&alias_ == pointer);
            }
        });
    }
}

// A plain ref static-array local denotes the source's storage, including its
// address. SystemLinker is the oracle for the shared address identity.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.refusal,
        "DMD CTFE refuses to compare static-array local addresses"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve ref static-array-local address identity"),
)) {
    @("pointer.staticArrayRefLocalPreservesAddressIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[2] source = [42, 99];
                ref int[2] alias_ = source;
                int[2]* pointer = &source;
                assert(&alias_ == pointer);
            }
        });
    }
}

// Element assignment through a ref static-array local writes the source's
// promoted native storage rather than an independent boxed snapshot.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve ref static-array-local element aliasing"),
)) {
    @("staticArray.refLocalElementWriteMutatesSource." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 42;
            }

            unittest {
                int[2] source = [seed, 43];
                int* pointer = &source[0];
                ref int[2] alias_ = source;
                alias_[0] = 99;
                assert(*pointer == 99);
                assert(source[0] == 99);
            }
        });
    }
}

// Taking an element address through a ref static-array local reaches the
// source's storage rather than promoting an independent alias snapshot.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve ref static-array-local element addresses"),
)) {
    @("pointer.staticArrayRefLocalElementUsesSourceStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 42;
            }

            int index() {
                return 1;
            }

            unittest {
                int[2] source = [seed, 43];
                ref int[2] alias_ = source;
                int* first = &alias_[0];
                int* second = &alias_[index];
                *first = 99;
                *second = 100;
                assert(source == [99, 100]);
            }
        });
    }
}

// Whole-value assignment through a ref nested-static-array local mutates the
// source's promoted native storage rather than rebinding it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.refusal,
        "DMD CTFE refuses the nested static-array element pointer cast"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve ref static-array-local assignment aliasing"),
)) {
    @("staticArray.refLocalAssignmentMutatesSource." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int number) {
                return number;
            }

            unittest {
                int[2][2] source = [[value(1), 2], [3, 4]];
                int* pointer = &source[0][0];
                ref int[2][2] alias_ = source;
                alias_ = [[value(99), 100], [101, 102]];
                assert(*pointer == 99);
                assert(source == [[99, 100], [101, 102]]);
            }
        });
    }
}

// Two ref static-array parameters bound from the same plain variable denote
// one storage location, including shared address and mutation identity.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.refusal,
        "DMD CTFE refuses to compare static-array parameter addresses"),
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve repeated ref static-array-argument identity"),
)) {
    @("staticArray.repeatedRefArgumentPreservesAddressIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void verify(ref int[2] first, ref int[2] second) {
                assert(&first == &second);
                first = [99, 100];
                assert(second == [99, 100]);
            }

            unittest {
                int[2] value = [42, 43];
                verify(value, value);
                assert(value == [99, 100]);
            }
        });
    }
}

// A plain ref class local denotes the source reference variable's storage,
// including its address. SystemLinker is the oracle for the shared address
// identity.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve ref class-local address identity"),
)) {
    @("pointer.classRefLocalPreservesAddressIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int value;
            }

            unittest {
                C source = new C();
                source.value = 42;
                ref C alias_ = source;
                C* pointer = &source;
                assert(&alias_ == pointer);
            }
        });
    }
}

// Assignment through a ref class local rebinds the source reference variable;
// the alias does not acquire an independent class-reference slot.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve ref class-local assignment aliasing"),
)) {
    @("class.refLocalAssignmentRebindsSource." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int value;
            }

            unittest {
                C source = new C();
                source.value = 42;
                ref C alias_ = source;
                C replacement = new C();
                replacement.value = 99;
                alias_ = replacement;
                assert(source is replacement);
                assert(source.value == 99);
            }
        });
    }
}

// `this`-reached class aliasing: a METHOD mutating `this.x` must be visible to
// another caller-side alias of the SAME object through the shared class
// cell, exactly like the `combine(a, b)` cross-frame aliasing case above,
// except the mutating write happens through `this` rather than an ordinary
// by-value parameter. `c.mutateAndCheck(c)` binds the receiver AND the
// by-value parameter `other` from the SAME argument expression `c`, so
// `other` gets a `classCells` entry shared with the caller's `c`
// (`registerClassArgumentAliases`) -- but `this` itself is bound from
// `receiver`, a plain boxed `Value` with no cell at all, so `this.x = 99`
// only updates the callee's own boxed `thisValue`, never the shared cell.
// `writeBackThis`'s post-call whole-value copy into the receiver's own
// location cannot save this: the divergence is observed DURING the call,
// inside the method's own frame, before that writeback ever runs. Only
// Interpreter and SystemLinker (the oracle) are pinned here per the
// omit-don't-pin convention.
static foreach (backend; Matrix!()) {
    @("class.methodMutatingThisIsVisibleThroughAliasedParameter." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;

                void mutateAndCheck(C other) {
                    this.x = 99;
                    assert(other.x == 99);
                }
            }

            unittest {
                C c = new C();
                c.mutateAndCheck(c);
            }
        });
    }
}

// `writeCelledLocal`'s `classCells` branch could not tell a reference REBIND
// (`c = b;`) apart from a whole-object field-write refresh, and unconditionally
// overwrote the (possibly SHARED) cell in place with the new object's fields --
// `c = b;` clobbered `a`'s own field values through the cell `a` and the OLD
// `c` shared, even though `registerClassAliasIfPlainVar` correctly re-points
// `c` at `b`'s own cell right afterwards: the damage to the shared cell already
// happened before that re-point ran. Only Interpreter and SystemLinker (the
// oracle) are pinned here per the omit-don't-pin convention.
static foreach (backend; Matrix!()) {
    @("class.reassigningAliasedVariableDoesNotCorruptOriginalObject." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;

                this(int v) {
                    x = v;
                }
            }

            int one() { return 1; }
            int two() { return 2; }

            unittest {
                auto a = new C(one());
                auto b = new C(two());
                auto c = a;
                c = b;
                assert(a.x == one());
            }
        });
    }
}

// A pointer into a class object follows the object, not the variable slot used
// to reach it. Rebinding that variable must therefore leave the pointer
// attached to the old object while subsequent field access follows the new
// reference.
static foreach (backend; Matrix!()) {
    @("class.fieldPointerSurvivesReferenceRebind." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;

                this(int value) {
                    x = value;
                }
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
                C oldObject = new C(one());
                C newObject = new C(two());
                C current = oldObject;
                int* pointer = &current.x;
                current = newObject;
                *pointer = ninetyNine();
                assert(oldObject.x == ninetyNine());
                assert(current.x == two());
            }
        });
    }
}

// `writeLocation`'s `DotVarExp` class arm re-derived the receiver via
// `runExpression(dot.e1)`, which for a class local is the STALE boxed
// `locals[variable]` mirror -- the plain `VarExp` read path has no
// `classValueFromCell` overlay, unlike the 3 cross-frame writeback helpers.
// Writing ONE field (`a.y = seven();`) then folded that stale receiver's OTHER
// fields back into the shared cell via `writeCelledLocal`'s whole-cell refresh,
// clobbering a DIFFERENT alias's earlier field write (`c.x = five();`) that
// `writeClassCellFieldIfPresent` had already correctly landed in the cell.
// Only Interpreter and SystemLinker (the oracle) are pinned here per the
// omit-don't-pin convention.
static foreach (backend; Matrix!()) {
    @("class.aliasedFieldWriteSurvivesUnrelatedFieldWriteThroughOriginal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;
                int y;
            }

            int one() { return 1; }
            int five() { return 5; }
            int seven() { return 7; }

            unittest {
                auto a = new C();
                a.x = one();
                auto c = a;
                c.x = five();
                a.y = seven();
                assert(c.x == five());
            }
        });
    }
}

// The CROSS-FRAME / nested-function-capture analog of the reference-rebind
// aliasing bug above
// (`class.reassigningAliasedVariableDoesNotCorruptOriginalObject`). A nested
// function rebinding a captured aliased class variable THROUGH an
// intermediate `null` (`c = null; c = new C(2); c.x = 5;`) used to drop this
// frame's own `classCells` entry for `c` without marking the rebind (the
// marker was gated on `value.isClassObject`, which `null` fails), so
// `writeBackNestedLocals`'s cross-frame reconciliation read the absent marker
// as "never rebound" and refreshed the PARENT's still-shared cell in place
// with the child's brand-new object, splicing it into whatever OTHER alias
// (`a` here) still shared that buffer -- NONDETERMINISTICALLY, depending on
// which of `child.locals`'s AA-ordered entries (`a` or `c`) the writeback
// reconciled last. Asserting on `a.x * 10 + c.x` in one expression means any
// AA order that loses either side (the aliased original OR the child's own
// final value) fails. Only Interpreter and SystemLinker (the oracle) are
// pinned here per the omit-don't-pin convention.
static foreach (backend; Matrix!()) {
    @("class.nestedFunctionRebindOfCapturedAliasedVariableDoesNotCorruptOriginal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int x;

                this(int v) {
                    x = v;
                }
            }

            unittest {
                auto a = new C(1);
                auto c = a;

                void n() {
                    c = null;
                    c = new C(2);
                    c.x = 5;
                }

                n();

                assert(a.x * 10 + c.x == 15);
            }
        });
    }
}

// `&value` of a `ref` parameter is emitted by DMD as AddrExp(VarExp), not the
// SymOffExp produced for a plain local; the interpreter must take the address
// of the parameter's slot.  cerealed's grainReinterpret(ref T) hits this.
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
// to close here.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "DMD CTFE refuses to convert a struct field's address to an " ~
        "integer at compile time (\"cannot cast '&Holder(7).value' to " ~
        "'ulong' at compile time\")"),
)) {
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

// addressOfExpression's DotVarExp branch minted a
// fresh `++allocationCount` identity on *every* evaluation of `&s.field`, so
// re-taking the same field's address gave a different identity each time
// (`&a.value !is &a.value`) — real D gives the same address back. Fixed by
// memoizing the allocation id per (receiver variable, field index). Ctfe
// omitted: DMD CTFE genuinely refuses this construct at compile time.
// Bytecode shares the typed-frame field-address path; Ctfe still rejects the
// pointer-identity comparison during compile-time evaluation.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "DMD CTFE genuinely refuses this pointer-identity construct at " ~
        "compile time"),
)) {
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

// Sibling of the identity fix above: writing through
// a `&s.field` pointer used to silently write into the pointer's own
// throwaway value snapshot instead of `s`'s storage, losing the write with
// no diagnostic. SystemLinker pins real D's actual (aliasing) write-through
// behaviour.
//
// `Holder` has exactly one scalar field of a plain struct LOCAL,
// address-taken via `&a.value` -- precisely the case the `structCells`
// native cell (already promoted at address-of time) now supports end to
// end. The Interpreter used to refuse this write outright
// (`shouldThrowWithMessage("Unsupported interpreter assignment target.")`,
// characterizing the pre-cell limitation); now it writes through the same
// cell exactly like SystemLinker's real aliasing. Bytecode was promoted
// onto this same fixture independently on master (bytecode struct field
// address write-through), so all three backends now share one fixture
// asserting the SAME value rather than a throw pinned only for Interpreter.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
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

// Extended to arrays: the same
// stale-cell bug `pointer.recursiveDeclarationDropsStaleScalarCell` names
// for `scalarCells`, but for `arrayCells`. Recursion reuses the same AST
// `VarDeclaration` for `a` at every call depth, and `child.arrayCells =
// arrayCells.dup` hands the inner frame the outer frame's already-promoted
// cell (shared by reference); without dropping it on `a`'s fresh
// re-declaration at the inner depth, `&a[0]` there resurrects the outer
// depth's stale cell instead of getting a fresh one for its own (shorter,
// differently-valued) array. SystemLinker is the oracle; other backends
// omitted per the omit-don't-pin convention (unconfirmed there).
static foreach (backend; Matrix!()) {
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
// refresh and masks this particular gap. SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
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

// Class sibling of `recursiveStructDeclarationDropsStaleStructCell` above:
// unlike the struct
// and array phases, the class phase has NO `dropClassCell` mirroring
// `dropStructCell`/`dropArrayCell`, so `runDeclarationExpression`'s fresh-
// binding cleanup never drops a stale `classCells` entry inherited via
// `child.classCells = classCells.dup`. Recursion reuses the same AST
// `VarDeclaration` for `c` at every call depth: depth 1 promotes a
// `classCells[c]` cell via `&c.x`, and `NativeBlock`'s `_bytes` is a slice
// (copying the handle, not the bytes), so the child depth-0 frame's duped
// `classCells[c]` entry shares the SAME underlying bytes as depth 1's. At
// depth 0, `c`'s fresh `C c = new C();` does not drop that stale/shared
// entry, so `c.x = valueForDepth(0);`'s whole-object refresh
// (`writeCelledLocal`'s `classCells` branch, unlike the struct branch which
// has nothing to refresh once `dropStructCell` removed it) mutates the
// SHARED bytes in place -- corrupting depth 1's own cell with depth 0's
// value. Depth 1's later `c.x` read (`classCellFieldValue`, authoritative
// over the boxed `locals` mirror) then observes depth 0's value instead of
// its own. SystemLinker (real, independent `new C()` allocations per depth)
// returns 1100, matching the struct sibling; before any production change
// Interpreter returned 100100 -- depth 0's own value corrupting depth 1's
// read twice over. SystemLinker is the oracle; other backends omitted per
// the omit-don't-pin convention (unconfirmed there).
static foreach (backend; Matrix!()) {
    @("pointer.recursiveClassDeclarationDropsStaleClassCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
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
                C c = new C();
                c.x = valueForDepth(depth);
                int* p = &c.x;
                if (depth == 0)
                    return *p;
                const inner = rec(depth - 1);
                return c.x * 1000 + inner;
            }

            unittest {
                assert(rec(1) == 1100);
            }
        });
    }
}

// `allocationId`/`fieldSnapshotAllocationId`
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

// `structFieldPointerVariables`/
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
static foreach (backend; Matrix!()) {
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

// Cross-frame struct-field-pointer
// write-through: the caller takes `&s.x` (promoting a
// `structCells` entry and a `structFieldPointerVariables`/
// `structFieldPointerFieldIndices` reverse-lookup entry in the CALLER's own
// frame), then passes the pointer into a callee that writes through it. The
// callee's own child `Walker` dupes `structCells` (so the cell's bytes are
// shared) but never dupes the reverse-lookup maps themselves, so the
// callee's `writeThroughStructFieldPointer` reverse-lookup misses and the
// write falls through to the `fieldSnapshotAllocationIds` refusal check
// (also duped) instead of aliasing. SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
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
// Ctfe omitted: `new`-with-user-ctor pointer indirection through a class
// field is not exercised on that backend yet. LLVMJit omitted: allocation ids
// are Interpreter-only
// bookkeeping with no compiled-code analogue, so promoting LLVMJit here
// would trivially pass without pinning anything meaningful.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed, "not exercised on this backend yet"),
    Omit!(LLVMJit, Because.unconfirmed,
        "vacuous on LLVMJit; promotion would trivially pass"),
)) {
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
// allocation id 0.
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; AliasSeq!(Bytecode, SystemLinker)) {
    @("refCall.assignmentToMemberRefReturnUsesReturnedBase." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Counter {
                int value;

                ref int slot(ref Counter other) {
                    return other.value;
                }
            }

            unittest {
                Counter receiver;
                Counter other;

                receiver.slot(other) = 42;

                assert(receiver.value == 0);
                assert(other.value == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Bytecode, SystemLinker)) {
    @("refCall.assignmentToConditionalMemberRefReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Counter {
                int value;

                ref int slot(bool useOther, ref Counter other) {
                    if (useOther)
                        return other.value;
                    return value;
                }
            }

            unittest {
                Counter receiver;
                Counter other;

                receiver.slot(true, other) = 42;

                assert(receiver.value == 0);
                assert(other.value == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Bytecode, SystemLinker)) {
    @("refCall.assignmentToMemberRefReturnEvaluatesReceiverOnce." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Counter {
                int value;

                ref int slot() {
                    return value;
                }
            }

            ref Counter receiver(ref Counter counter, ref int evaluations) {
                ++evaluations;
                return counter;
            }

            unittest {
                Counter counter;
                int evaluations;

                receiver(counter, evaluations).slot() = 42;

                assert(evaluations == 1);
                assert(counter.value == 42);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Bytecode, SystemLinker)) {
    @("refCall.assignmentToMemberRefReturnEvaluatesRefArgumentOnce." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Counter {
                int value;

                ref int slot() {
                    return value;
                }
            }

            Counter* pointed(ref Counter counter, ref int evaluations) {
                ++evaluations;
                return &counter;
            }

            ref Counter receiver(ref Counter counter) {
                return counter;
            }

            unittest {
                Counter counter;
                int evaluations;

                receiver(*pointed(counter, evaluations)).slot() = 42;

                assert(evaluations == 1);
                assert(counter.value == 42);
            }
        });
    }
}

// `new S` of a struct with a dynamic-array field passes the field's `null`
// default initialiser as a positional argument; the interpreter must store it
// as an empty array so a null array's `.length` is 0 (compiled D:
// `(new S).arr.length == 0`).  cerealed's Appender (`new Data` then
// `_data.arr.length`) hits this.
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!(Omit!(Ctfe, Because.unconfirmed))) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

// `a ~= x` grew the boxed array but left
// a promoted `arrayCells` entry (here promoted by `&a[0]`) at its OLD
// length. A subsequent in-bounds write to the newly-appended element
// (`a[1] = five();`) is unaffected -- `writeThroughArrayCell` is a silent
// no-op past the cell's own length -- but `readIndexExpression`'s cell arm
// still answers the following read from the stale, too-short cell, which
// used to throw a spurious out-of-range error before the fix. SystemLinker
// is the oracle.
static foreach (backend; Matrix!()) {
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

// `runSliceAssignExpression`'s bounded
// form (`a[i .. j] = x`) writes `locals[variable]` directly but never
// refreshes a promoted `arrayCells` entry -- here promoted by `&a[0]` --
// which `readIndexExpression`'s cell arm reads in preference to the boxed
// mirror. Only indices `0 .. 2` are assigned; `a[2]` must stay untouched.
// See the sibling `dynamicArray.sliceFillAssignmentWritesThroughSlicePromotedCell`
// fixture in arrays.d for the full-slice-fill variant. SystemLinker is the
// oracle.
static foreach (backend; Matrix!()) {
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

// `bump(int[] s)` binds `s` via
// `recordParameterSliceAlias` -- a slice-expression argument never calls
// `promoteSliceArrayCell`, so `s` itself never gets an `arrayCells` entry --
// while `a`, the slice's source, already has one (promoted here by
// `&a[0]`). `s[0] = ninetyNine();` reached `writeThroughSliceAlias`, which
// refreshed only the boxed `locals` mirror for `a`, never `a`'s own
// promoted cell; the following `return a[0];` reads through
// `readIndexExpression`'s cell arm, which is authoritative over the boxed
// mirror and so kept answering with the stale, pre-write value.
// SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
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

// `writePointerTarget` called
// `writeThroughArrayPointer` but not `writeThroughStructFieldPointer`, so
// `(*p)++` through a struct-field pointer read the promoted `structCells`
// entry (via `pointerTargetValue`/`structFieldPointerCellValue`) but wrote
// only the pointer's own boxed snapshot back through the fallback
// `writeLocation` call at the bottom of `writePointerTarget` -- the next
// `*p` re-read the stale cell instead of the freshly-incremented value.
// SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
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

// Once `&s.x` has promoted a `structCells`
// entry for `s`, a `ref` LOCAL bound directly to `s.x` (recorded via
// `recordStructFieldAlias`/`structFieldAliases`, the only reachable path to
// `writeThroughStructFieldAlias`) writes `ninetyNine()` through
// `writeThroughStructFieldAlias`, which refreshed only the boxed `locals`
// mirror for `s`, never `s`'s own promoted cell. The following `return *p;`
// reads through `pointerTargetValue`/`structFieldPointerCellValue`, which is
// authoritative over the boxed mirror and so kept answering with the stale,
// pre-write value. SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
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

// A ref local bound to a direct scalar class field denotes the same storage
// as an earlier pointer to that field. SystemLinker is the oracle.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet preserve class-field ref-local identity"),
)) {
    @("pointer.classFieldRefLocalPreservesAddressIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int value;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                auto c = new C;
                auto p = &c.value;
                ref int r = c.value;
                assert(&r == p);
                r = ninetyNine();
                assert(*p == 99);
                assert(c.value == 99);
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
static foreach (backend; Matrix!()) {
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

// `recordStructFieldAlias` records ANY
// `DotVarExp` initializer bound to a `ref` local -- including a non-scalar
// (array/nested-struct) field -- so `writeThroughStructFieldAlias` reached a
// promoted `structCells` entry for a field it cannot represent as a native
// scalar. Once `&s.x` has promoted `s`'s cell, a later `ref int[] r = s.arr;
// r = [...]` write walked into the same unguarded `writeScalar` call the
// scalar sibling uses, which throws on a non-scalar field type. Expect the
// unrelated `s.x` field to still read `1`: the array-field write must skip
// the cell write entirely and leave the boxed mirror path (unaffected by
// this finding) as the sole record for a non-scalar aliased field.
static foreach (backend; Matrix!()) {
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

// `writeCelledLocal`'s plain
// rebind arm (`a = [...]`, no recursion involved at all) dropped
// `arrayCells[variable]` but never the memoized `arrayAllocations`/
// `arrayAllocationVariables` id -- the same per-binding fresh-id principle
// established above, applied incompletely to this arm. A pointer
// taken BEFORE the rebind (`p`) kept resolving, via the still-live reverse
// map, into the REBOUND array's own freshly-promoted cell instead of
// declining to its own frozen snapshot. Before any production change,
// Interpreter returned 7 (the rebound array's first element) instead of the
// pre-rebind value 1. SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
    @("pointer.arrayPointerTakenBeforePlainRebindKeepsPreRebindValue." ~
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

            int seven() {
                return 7;
            }

            int eight() {
                return 8;
            }

            int f() {
                int[] a = [one(), two()];
                int* p = &a[0];
                a = [seven(), eight()];
                int* q = &a[0];
                return *p;
            }

            unittest {
                assert(f() == 1);
            }
        });
    }
}

// Crash twin of the same finding: the outer pointer indexes past the END of
// the rebound (shorter) array. Before any production change, Interpreter
// resolved the stale outer id into the rebound array's own (shorter) cell
// and threw `NativeArray.element: index out of range` instead of declining
// to the outer pointer's own frozen (in-range) snapshot.
static foreach (backend; Matrix!()) {
    @("pointer.arrayPointerTakenBeforePlainRebindToShorterArrayDoesNotCrash." ~
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

            int nine() {
                return 9;
            }

            int f() {
                int[] a = [one(), two()];
                int* p = &a[1];
                a = [nine()];
                int* q = &a[0];
                return *p;
            }

            unittest {
                assert(f() == 2);
            }
        });
    }
}

// Append twin of the same finding: `runArrayAppendAssignExpression` (`~=`)
// has the identical drop-cell-keep-id shape as the plain-rebind arm above --
// `arrayCells.remove(variable)` alone, without also invalidating the
// memoized id, means a pointer re-taken AFTER the append (`q`) mints the
// SAME id as one taken BEFORE it (`p`), because `a` itself was never
// re-declared, so a write through `q` into the post-append cell became
// visible through `p` too. A three-element array literal's GC block has
// exactly enough spare capacity for 3 elements and none for a 4th (verified
// separately against a standalone compiled program), so appending a 4th
// here deterministically reallocates in real D -- `p`, taken before the
// append, no longer aliases `a`'s post-append storage at all, and keeps
// reading its own pre-append snapshot even after a write through `q`.
// SystemLinker is the oracle for this exact value.
static foreach (backend; Matrix!()) {
    @("pointer.arrayPointerTakenBeforeAppendKeepsPreAppendValue." ~
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

            int seven() {
                return 7;
            }

            int ninetyNine() {
                return 99;
            }

            int f() {
                int[] a = [one(), two(), three()];
                int* p = &a[0];
                a ~= seven();
                int* q = &a[0];
                *q = ninetyNine();
                return *p;
            }

            unittest {
                assert(f() == 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("pointer.borrowedSliceAppendRebindsWhenGrowthFails." ~ backend.stringof)
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

            unittest {
                int[] array = [one(), two(), three()];
                int[] slice = array[0 .. 1];
                int* pointer = &slice[0];
                slice ~= four();
                assert(slice == [1, 4]);
                assert(array == [1, 2, 3]);
                assert(*pointer == 1);
            }
        });
    }
}

// `mergeArrayAllocationMaps`
// unconditionally unions a child's reverse (`arrayAllocationVariables`)
// entries into the parent. A child's OWN fresh rebind of a shared
// `VarDeclaration` mints a FRESH id for its own cell (per the per-binding
// fresh-id principle above), and
// dynamic-array elements are GC-allocated, so a pointer into that fresh
// child cell may legally escape upward (returned from the child). The
// reverse map is keyed by `VarDeclaration`, not by binding, so routing that
// child-minted id into the PARENT frame -- which holds its OWN live cell for
// a DIFFERENT binding of the SAME `VarDeclaration` -- resolves the escaped
// pointer through the parent's bytes instead of declining to its own frozen
// snapshot. Before any production change, Interpreter's `*leak(1)` returned
// 111 (`leak(1)`'s own outer `a`, resolved through the wrongly-merged id)
// instead of 11 (`leak(0)`'s inner `a`, the value the escaped pointer
// actually names). SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
    @("pointer.childMintedArrayIdEscapingUpwardDoesNotResolveThroughParentCell." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int eleven() {
                return 11;
            }

            int two() {
                return 2;
            }

            int* leak(int depth) {
                int[] a = [depth * 100 + eleven(), two()];
                int* p = &a[0];
                if (depth == 0)
                    return p;
                int* q = leak(0);
                return (*q == 11) ? q : null;
            }

            unittest {
                assert(*leak(1) == 11);
            }
        });
    }
}

// Cross-frame cell staleness: the parent's
// promoted `arrayCells` entry is READ-AUTHORITATIVE (`runIndexExpression`'s
// cell arm shadows the boxed `locals` mirror), but `writeBackNestedLocals`
// only ever refreshed the parent's boxed `locals` mirror with a bare
// assignment, never reconciling the parent's own `arrayCells` entry. Once a
// nested function rebinds a captured array (`a = [...]`, same length), the
// parent's stale cell kept answering `a[0]` with the pre-call value even
// though the boxed mirror was correctly refreshed. SystemLinker is the
// oracle.
static foreach (backend; Matrix!()) {
    @("pointer.nestedFunctionArrayRebindIsVisibleThroughParentCell." ~
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

            int seven() {
                return 7;
            }

            int eight() {
                return 8;
            }

            int nine() {
                return 9;
            }

            int f() {
                int[] a = [one(), two(), three()];
                int* p = &a[0];
                void g() {
                    a = [seven(), eight(), nine()];
                }
                g();
                return a[0];
            }

            unittest {
                assert(f() == 7);
            }
        });
    }
}

// Crash twin of the cross-frame cell staleness bug above: a nested function GROWING a captured
// array (`a ~= x`) changes its length, so the parent's stale `arrayCells`
// entry -- never reconciled by `writeBackNestedLocals` -- is not merely
// wrong but too SHORT for the post-append index, and
// `runIndexExpression`'s bounds check consults the (correctly refreshed)
// boxed `locals` mirror's length, not the cell's, so the out-of-range cell
// read crashes the host instead of throwing a `RangeError`. SystemLinker is
// the oracle.
static foreach (backend; Matrix!()) {
    @("pointer.nestedFunctionArrayAppendGrowsArrayVisibleThroughParentCell." ~
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

            int f() {
                int[] a = [one(), two(), three()];
                int* p = &a[0];
                void g() {
                    a ~= four();
                }
                g();
                return a[3];
            }

            unittest {
                assert(f() == 4);
            }
        });
    }
}

// Recursion twin of the cross-frame cell staleness bug above, with no nesting at all: a dynamic-
// array PARAMETER (not `ref`) shares its backing storage across recursive
// calls exactly like real D. `writeBackArrayPointerTargets` -- the
// `writeBackNestedLocals` counterpart for a variable whose address was
// taken via `arrayAllocationVariables` rather than capture -- has the same
// bare-assignment gap, so a same-length in-place element write made by the
// recursive callee never reconciled the caller's own stale cell.
// SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
    @("pointer.recursiveArrayParameterElementWriteIsVisibleThroughCallerCell." ~
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

            int f(int[] a, int depth) {
                int* p = &a[0];
                if (depth == 0) {
                    a[0] = five();
                    return 0;
                }
                f(a, 0);
                return a[0];
            }

            unittest {
                assert(f([one(), two()], 1) == 5);
            }
        });
    }
}

// Cross-frame sibling of the same-frame `s = b;` rebind fixture: a `ref
// int[]` parameter REBOUND to a
// new same-length array inside the callee must give the caller's own
// variable fresh storage WITHOUT corrupting a pre-existing slice VIEW of
// the caller's OLD storage. `writeBackRefArguments` routes the parameter's
// final value through `writeCelledLocal(..., arrayIsRefWriteback: true)`,
// whose same-length arm refreshes the caller's cell bytes IN PLACE -- correct
// for a genuine element mutation flowing through shared storage, but wrong
// here: `s`'s own `arrayCells` entry shares the SAME `NativeArray` block as
// `a`'s (via `promoteSliceArrayCell`), so the in-place refresh overwrites
// `s`'s view with the REBOUND array's bytes even though real D gives `a`
// entirely new storage and leaves `s`'s old view untouched. SystemLinker is
// the oracle.
static foreach (backend; Matrix!()) {
    @("pointer.refParameterRebindDoesNotCorruptPreexistingSliceView." ~
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

            int seven() {
                return 7;
            }

            int eight() {
                return 8;
            }

            void g(ref int[] p) {
                p = [seven(), eight()];
            }

            int f() {
                int[] a = [one(), two()];
                int[] s = a[];
                g(a);
                return s[0];
            }

            unittest {
                assert(f() == 1);
            }
        });
    }
}

// Nested-capture twin of the fixture above: a nested function rebinding a
// CAPTURED array to a new same-length array must not corrupt a pre-existing
// slice view of the captured array's OLD storage, via
// `writeBackNestedLocals`'s own use of the same `writeCelledLocal(...,
// arrayIsRefWriteback: true)` reconciliation. SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
    @("pointer.nestedFunctionArrayRebindDoesNotCorruptPreexistingSliceView." ~
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

            int seven() {
                return 7;
            }

            int eight() {
                return 8;
            }

            int f() {
                int[] a = [one(), two()];
                int[] s = a[];
                void g() {
                    a = [seven(), eight()];
                }
                g();
                // Both must hold at once: `a` sees the REBIND (fresh
                // storage), `s` keeps its pre-existing view of the OLD
                // storage untouched. Checking only one of the two would pass
                // "by accident" depending on `locals` AA iteration order (the
                // parent's own `a` and the untouched `s` are BOTH written
                // back through the same `child.locals` walk in
                // `writeBackNestedLocals`, so whichever is processed last
                // currently wins the shared block's bytes) -- combining both
                // into one result makes the corruption observable regardless
                // of that order.
                return a[0] * 10 + s[0];
            }

            unittest {
                assert(f() == 71);
            }
        });
    }
}


// Array-of-struct widening: `promoteArrayCell` previously
// only gave `arrayCells` an entry when the element type was `native_scalar.
// isNativeScalarType`, so `&a[i]` on an array of structs stayed on the
// boxed-snapshot path (`arrayPointer`'s VarExp branch still minted an
// `arrayAllocationVariables` id via `allocationId`, but no cell backed it,
// so `runPointerExpression`'s `arrayPointerCellValue` check always missed
// and fell to the frozen `pointer.pointerTarget` snapshot taken at
// address-of time). A direct whole-element write (`a[i] = S(...)`) after
// `&a[i]` was taken was therefore invisible through the earlier pointer.
// Before any production change, Interpreter returned 1 (the pre-write
// snapshot) instead of 99. SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
    @("pointer.structArrayElementWrittenDirectlyIsVisibleThroughEarlierPointer." ~
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

            int ninetyNine() {
                return 99;
            }

            unittest {
                S[] a = [S(one()), S(one())];
                S* p = &a[0];
                a[0] = S(ninetyNine());
                assert((*p).x == 99);
            }
        });
    }
}

// A promoted array-of-struct cell is authoritative for a whole-array read,
// not only for an indexed element read. Passing the array onward after a
// pointer write must therefore reconstruct its struct elements from the cell
// instead of copying the stale boxed mirror into the callee.
static foreach (backend; Matrix!()) {
    @("array.wholeStructArrayArgumentReadsAuthoritativeCell." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int x;
            }

            void put(S* pointer, int value) {
                *pointer = S(value);
            }

            int observe(S[] values) {
                return values[0].x;
            }

            unittest {
                S[] values = [S(42)];
                S* pointer = &values[0];
                put(pointer, 99);
                assert(observe(values) == 99);
            }
        });
    }
}

// A promoted array-of-static-array cell is authoritative for a whole-array
// read, not only for an indexed element read. Passing the array onward after
// a pointer write must therefore reconstruct its static-array elements from
// the cell instead of copying the stale boxed mirror into the callee.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "does not yet support storing a whole static array through a pointer"),
)) {
    @("array.wholeStaticArrayArgumentReadsAuthoritativeCell." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void put(int[2]* pointer, int value) {
                *pointer = [value, value];
            }

            int observe(int[2][] values) {
                return values[0][0];
            }

            unittest {
                int[2][] values = [[42, 42]];
                int[2]* pointer = &values[0];
                put(pointer, 99);
                assert(observe(values) == 99);
            }
        });
    }
}

// Nested static-array indexing scales each step by its immediate element
// type. Taking a scalar leaf's address must therefore retain the outer row
// stride instead of treating the outer index as a scalar-element offset.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "DMD CTFE asserts internally while initializing the nested array"),
)) {
    @("pointer.nestedStaticArrayElementUsesImmediateStride." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void put(int* pointer, int value) {
                *pointer = value;
            }

            unittest {
                int[2][] values = [[1, 2], [3, 4]];
                int* pointer = &values[1][0];
                put(pointer, 99);
                assert(values[0][1] == 2);
                assert(values[1][0] == 99);
            }
        });
    }
}

// A plain nested static-array local uses one authoritative native cell once a
// scalar leaf's address is taken. SystemLinker's pointer aliases that leaf,
// so a later direct write to it must be visible through the earlier pointer.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "DMD CTFE rejects the nested static-array element pointer cast"),
)) {
    @("pointer.nestedStaticArrayLocalDirectWriteIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                int[2][2] values;
                values[1][0] = one;
                int* pointer = &values[1][0];
                values[1][0] = ninetyNine;
                assert(*pointer == 99);
            }
        });
    }
}

// Array-element/nested-field composition follow-up:
// composing the two slices above -- a nested struct field OF an
// array-of-struct element, `&a[i].inner.x`. `addressOfExpression`'s
// `DotVarExp` branch only called `promoteNestedStructFieldCell`, which
// requires the nested field's own receiver (`innerDot.e1`) to be a plain
// `VarExp`; here it is an `IndexExp` (`a[0]`), so no cell ever backed this
// pointer and it stayed on the boxed snapshot taken at address-of time.
// Before any production change, Interpreter returned 1 (the pre-write
// snapshot) instead of 99. SystemLinker is the oracle. Ctfe/Bytecode/LLVMJit
// omitted per the omit-don't-pin convention (unconfirmed there).
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "computes a wrong value for this shape (`1 != 99`), not a refusal"),
)) {
    @("pointer.arrayElementNestedStructFieldWrittenDirectlyIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            struct S {
                Inner inner;
            }

            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                S[] a = [S(Inner(one()))];
                int* p = &a[0].inner.x;
                a[0].inner.x = ninetyNine();
                assert(*p == 99);
            }
        });
    }
}

// `dropArrayCell` cleaned only
// `arrayCells` plus the `arrayAllocations`/`arrayAllocationVariables` memo --
// it never invalidated the `arrayNestedStructFieldPointer*` reverse-lookup
// maps the fixture above populates, unlike every OTHER pointer family
// (`dropStructCell`/`dropClassCell` both clean their own reverse lookups on a
// fresh binding). A `foreach` body re-executes the same `DeclarationExp` for
// `a` every iteration; the first iteration's `&a[0].inner.x` pointer's id
// stayed mapped, via the uncleaned maps, to the SAME `VarDeclaration`, so
// dereferencing it after the second iteration's fresh binding resolved into
// THAT binding's freshly-promoted cell instead of correctly declining to the
// first iteration's own frozen snapshot. Before any production change,
// Interpreter returned 99 (the second iteration's value) instead of 5 (the
// first iteration's value, read through the pointer saved back then).
// SystemLinker is the oracle; other backends omitted per the
// omit-don't-pin convention (unconfirmed there).
static foreach (backend; Matrix!()) {
    @("pointer.loopRedeclaredArrayNestedStructFieldPointerKeepsPreRebindValue." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            struct S {
                Inner inner;
            }

            int five() {
                return 5;
            }

            int ninetyNine() {
                return 99;
            }

            int f() {
                int result;
                int* saved;
                foreach (iter; 0 .. 2) {
                    S[] a = [S(Inner(iter == 0 ? five() : ninetyNine()))];
                    if (iter == 0) {
                        saved = &a[0].inner.x;
                    } else {
                        int* q = &a[0].inner.x;
                        result = *saved;
                    }
                }
                return result;
            }

            unittest {
                assert(f() == 5);
            }
        });
    }
}

// Struct-static-array-field follow-up:
// `&s.arr[i]` where `arr` is a static-array field of a plain struct local.
// `arrayPointer`'s `array.isDotVarExp` branch minted a fresh `++
// allocationCount` id for this shape with no reverse-lookup registration at
// all, so a direct element write to the field (`s.arr[0] = ...`) after the
// pointer was taken stayed invisible through it -- the same snapshot gap the
// struct-scalar-field phase closed for `&s.field`, and the array phase
// closed for `&a[i]`. SystemLinker's `p` aliases `s`'s real storage, so the
// direct write is visible through `*p`. Other backends omitted per the
// omit-don't-pin convention (unconfirmed there).
static foreach (backend; Matrix!()) {
    @("pointer.structStaticArrayFieldElementWrittenDirectlyIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int[3] arr;
            }

            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                S s;
                s.arr[0] = one();
                int* p = &s.arr[0];
                s.arr[0] = ninetyNine();
                assert(*p == 99);
            }
        });
    }
}

// Struct-static-array-field follow-up, foreach-ref
// mutation shape: `foreach (ref e; s.arr) e = ...;` lowers (dmd's own
// foreach-to-for rewrite) to `T[] __r = s.arr[]; ... ref T e = __r[__key];`,
// so the write lands through a SLICE alias of the field, not a direct
// `s.arr[i] = ...` assignment -- the write-through path the fixture above
// exercises. SystemLinker's `p` aliases `s`'s real storage, so the write is
// visible through `*p`. `Ctfe`/`LLVMJit` omitted per the omit-don't-pin
// convention (unconfirmed there).
static foreach (backend; Matrix!()) {
    @("pointer.structStaticArrayFieldElementWrittenByForeachRefIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int[3] arr;
            }

            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                S s;
                s.arr[0] = one();
                int* p = &s.arr[0];
                foreach (ref e; s.arr)
                    e = e + ninetyNine();
                assert(*p == 1 + 99);
            }
        });
    }
}

// Class sibling of the struct-static-array-field fixture above:
// `&c.arr[i]` where
// `arr` is a scalar-element static-array field of a plain class local `c`.
// `arrayPointer`'s `array.isDotVarExp` branch only calls
// `promoteStructArrayFieldCell`, which requires `variable.type.toBasetype.
// isTypeStruct` (a no-op for a class receiver), so no cell backs this
// pointer and a direct element write (`c.arr[0] = ...`) after the pointer
// was taken stays invisible through it -- the same snapshot gap the
// struct-static-array-field slice closed for a struct receiver. SystemLinker's
// `p` aliases `c`'s real storage, so the direct write is visible through
// `*p`. Other backends omitted per the omit-don't-pin convention
// (unconfirmed there).
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws its own unrelated \"Unsupported assignment in bytecode core: c.arr[0] = one()\" for this shape, not a wrong value"),
)) {
    @("pointer.classStaticArrayFieldElementWrittenDirectlyIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int[3] arr;
            }

            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                C c = new C();
                c.arr[0] = one();
                int* p = &c.arr[0];
                c.arr[0] = ninetyNine();
                assert(*p == 99);
            }
        });
    }
}

// Class-static-array-field follow-up, foreach-ref
// mutation shape: the class sibling of `pointer.
// structStaticArrayFieldElementWrittenByForeachRefIsVisibleThroughEarlierPointer`
// above -- `foreach (ref e; c.arr) e = ...;` lowers (dmd's own foreach-to-for
// rewrite) to `T[] __r = c.arr[]; ... ref T e = __r[__key];`, so the write
// reaches `c` through a SLICE alias of the field, not the direct
// `c.arr[i] = ...` write path `pointer.
// classStaticArrayFieldElementWrittenDirectlyIsVisibleThroughEarlierPointer`
// already covers. `recordSliceAlias`'s `DotVarExp` branch computed the
// field index via `structFieldIndex(dot)` unconditionally, which requires
// `receiverStructType` and throws "Unsupported interpreter field access."
// immediately for a class receiver -- this shape was entirely unsupported
// (not merely missing pointer-aliasing), so a plain (pointer-free)
// `foreach (ref e; c.arr) e = ...;` already threw. SystemLinker's `p`
// aliases `c`'s real storage, so the write is visible through `*p`.
// `Ctfe`/`LLVMJit` omitted per the omit-don't-pin convention (unconfirmed
// there), matching the struct sibling fixture's own backend set.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws its own unrelated \"Unsupported assignment in bytecode core: c.arr[0] = one()\" for this shape, not a wrong value"),
)) {
    @("pointer.classStaticArrayFieldElementWrittenByForeachRefIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int[3] arr;
            }

            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                C c = new C();
                c.arr[0] = one();
                int* p = &c.arr[0];
                foreach (ref e; c.arr)
                    e = e + ninetyNine();
                assert(*p == 1 + 99);
            }
        });
    }
}

// Write-through-pointer follow-up: the opposite direction of `pointer.
// classStaticArrayFieldElementWrittenDirectlyIsVisibleThroughEarlierPointer`
// above -- write THROUGH `&c.arr[i]`, then read `c.arr[i]` directly --
// mirroring `pointer.nestedClassStructFieldWrittenThroughPointerIsVisibleDirectly`'s
// shape but for the static-array-field aggregate-composition shape instead
// of the nested-struct-field one. Other backends omitted per the
// omit-don't-pin convention, matching the other class fixtures' own backend
// set.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws its own unrelated \"Unsupported assignment in bytecode core: c.arr[0] = one()\" for this shape, not a wrong value"),
)) {
    @("pointer.classArrayFieldElementWrittenThroughPointerIsVisibleDirectly." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int[3] arr;
            }

            int one() {
                return 1;
            }

            unittest {
                C c = new C();
                c.arr[0] = one();
                int* p = &c.arr[0];
                *p = 5;

                assert(c.arr[0] == 5);
            }
        });
    }
}

// Cross-frame follow-up: the
// class-receiver sibling of `pointer.
// structArrayFieldWriteThroughPointerInCalleeIsVisibleToCaller` above. The
// caller takes `&c.arr[0]` (promoting a `classCells` entry and a
// `classArrayFieldPointerVariables`/`classArrayFieldPointerFieldIndices`
// reverse-lookup entry in the CALLER's own frame), then passes the pointer
// into a callee that writes through it. The callee's own child `Walker` dupes
// `classCells` (so the cell's bytes are shared) but, before this slice, never
// duped the reverse-lookup maps themselves, so the callee's
// `writeThroughClassArrayFieldPointer` reverse-lookup missed and the write
// fell through to the `fieldSnapshotAllocationIds` refusal check (also duped)
// instead of aliasing. SystemLinker is the oracle; Bytecode omitted per the
// omit-Bytecode convention.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws its own unrelated \"Unsupported assignment in bytecode core: c.arr[0] = one()\" for this shape, not a wrong value"),
)) {
    @("pointer.classArrayFieldWriteThroughPointerInCalleeIsVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C {
                int[3] arr;
            }

            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            void put(int* p, int v) {
                *p = v;
            }

            int f() {
                C c = new C();
                c.arr[0] = one();
                int* p = &c.arr[0];
                put(p, ninetyNine());
                return *p + c.arr[0];
            }

            unittest {
                assert(f() == 198);
            }
        });
    }
}

// Nested-struct-field follow-up: `&s.inner.x` where `inner` is a
// (non-union) struct field of a
// plain struct local and `x` is a scalar field of `inner`.
// `addressOfExpression`'s `DotVarExp` branch resolves `fieldSnapshotAllocationId`/
// `promoteStructFieldCell` only for a `dot.e1.isVarExp` receiver; here
// `dot.e1` (`s.inner`) is itself a `DotVarExp`, so neither ever registers a
// reverse lookup for the minted id, and `writeLocation`'s `PtrExp` arm falls
// through to its "every other `&s.field` snapshot" guard and throws
// "Unsupported interpreter assignment target." SystemLinker's `p` aliases
// `s`'s real storage, so the write through `*p` is visible via `s.inner.x`.
// Other backends omitted per the omit-don't-pin convention (unconfirmed
// there).
static foreach (backend; Matrix!()) {
    @("pointer.addressOfNestedStructFieldWriteThroughUpdatesField." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            struct S {
                Inner inner;
            }

            int seed() {
                return 7;
            }

            unittest {
                S s = S(Inner(seed()));
                int* p = &s.inner.x;
                *p = 5;

                assert(s.inner.x == 5);
            }
        });
    }
}

// Pointer-identity memoization follow-up, the nested-field
// sibling of `pointer.addressOfStructFieldIsStableAcrossReEvaluation` above:
// `fieldSnapshotAllocationId` only memoizes an id per (receiver variable,
// field index) when `dot.e1` resolves directly to a `VarExp` -- for
// `&s.inner.x`, `dot.e1` is itself a `DotVarExp` (`s.inner`), so the
// function always took its non-`VarExp`-receiver fresh-id fallback
// (`++allocationCount` every evaluation), a real, previously-documented and
// deferred gap ("the full field-PATH generalization"). SystemLinker is the
// oracle; Ctfe/Bytecode/LLVMJit omitted per the omit-don't-pin convention
// (unconfirmed there).
static foreach (backend; Matrix!()) {
    @("pointer.addressOfNestedStructFieldIsStableAcrossReEvaluation." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            struct S {
                Inner inner;
            }

            int seed() {
                return 7;
            }

            unittest {
                S s = S(Inner(seed()));
                int* p = &s.inner.x;

                assert(p is &s.inner.x);
                assert(*p == 7);
            }
        });
    }
}

// Cross-frame pointer-identity follow-up (54d0bb99's own
// deferred gap): `nestedFieldAddressAllocations` memoizes `&s.inner.x`'s
// allocation id only within the SAME `Walker` frame -- a nested function
// closing over `s` (the identical `VarDeclaration`, no rebind at all) runs
// in its own child frame, and since that memo map was never duped into a
// child frame, re-taking `&s.inner.x` from inside the nested function
// minted a brand-new id instead of returning the outer frame's own
// memoized one. Real D shares the exact same stack storage between an
// outer function and a nested function closing over its locals, so the two
// addresses must compare equal. SystemLinker is the oracle; Ctfe/Bytecode/
// LLVMJit omitted per the omit-don't-pin convention (unconfirmed there).
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws its own unrelated \"Unsupported expression in bytecode core: &s.inner.x\" for this shape, not a wrong value"),
)) {
    @("pointer.addressOfNestedStructFieldIsStableAcrossNestedFunctionCall." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            struct S {
                Inner inner;
            }

            int seed() {
                return 7;
            }

            bool sameAddressAcrossNestedCall() {
                S s = S(Inner(seed()));
                int* p = &s.inner.x;
                int* q;

                void capture() {
                    q = &s.inner.x;
                }

                capture();
                return p is q;
            }

            unittest {
                assert(sameAddressAcrossNestedCall());
            }
        });
    }
}

// `&a[i]` on a dynamic array whose element type is itself a scalar-element
// static array (`int[2][]`) -- the array-of-static-array sibling of the
// array-of-struct fixture above. `promoteArrayCell` previously stopped at
// `isNativeScalarType`/struct element types, so a static-array element
// stayed on the boxed-snapshot path exactly as struct elements once did:
// `arrayPointer`'s VarExp branch still mints an `arrayAllocationVariables`
// id, but no cell backed it, so `arrayPointerCellValue` always missed and
// fell to the frozen `pointer.pointerTarget` snapshot taken at address-of
// time. Before any production change, Interpreter returned 1 (the pre-write
// snapshot) instead of 99; confirmed via an unnamed scratch probe with the
// identical body before the fixture was given its real name and committed.
// SystemLinker is the oracle.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "computes a wrong value for this shape (`-1849532000 != 99`), not a refusal"),
)) {
    @("pointer.staticArrayElementWrittenDirectlyIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            unittest {
                int[2][] a = [[one(), one()], [one(), one()]];
                int[2]* p = &a[0];
                a[0] = [ninetyNine(), ninetyNine()];
                assert((*p)[0] == 99);
            }
        });
    }
}

// Struct-static-array-field cross-frame follow-up: the
// array-typed-field sibling of `pointer.
// structFieldWriteThroughPointerInCalleeIsVisibleToCaller` above. The caller
// takes `&s.arr[0]` (promoting a `structCells` entry and a
// `structArrayFieldPointerVariables`/`structArrayFieldPointerFieldIndices`
// reverse-lookup entry in the CALLER's own frame), then passes the pointer
// into a callee that writes through it. The callee's own child `Walker`
// dupes `structCells` (so the cell's bytes are shared) but, before this
// slice, never duped the reverse-lookup maps themselves, so the callee's
// `writeThroughStructArrayFieldPointer` reverse-lookup missed and the write
// fell through to the `fieldSnapshotAllocationIds` refusal check (also
// duped) instead of aliasing. SystemLinker is the oracle; Bytecode omitted
// per the omit-Bytecode convention.
static foreach (backend; Matrix!()) {
    @("pointer.structArrayFieldWriteThroughPointerInCalleeIsVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                int[3] arr;
            }

            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            void put(int* p, int v) {
                *p = v;
            }

            int f() {
                S s;
                s.arr[0] = one();
                int* p = &s.arr[0];
                put(p, ninetyNine());
                return *p + s.arr[0];
            }

            unittest {
                assert(f() == 198);
            }
        });
    }
}

// Nested-struct-field cross-frame follow-up: the
// nested-field sibling of `pointer.
// structArrayFieldWriteThroughPointerInCalleeIsVisibleToCaller` above. The
// caller takes `&s.inner.x` (promoting a `structCells` entry and a
// `nestedStructFieldPointerVariables`/`...OuterFieldIndices`/
// `...InnerFieldIndices` reverse-lookup entry in the CALLER's own frame),
// then passes the pointer into a callee that writes through it. The
// callee's own child `Walker` dupes `structCells` (so the cell's bytes are
// shared) but, before this slice, never duped the reverse-lookup maps
// themselves, so the callee's `writeThroughNestedStructFieldPointer`
// reverse-lookup missed and the write fell through to the
// `fieldSnapshotAllocationIds` refusal check (also duped) instead of
// aliasing. SystemLinker is the oracle; Bytecode omitted per the
// omit-Bytecode convention.
static foreach (backend; Matrix!()) {
    @("pointer.nestedStructFieldWriteThroughPointerInCalleeIsVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            struct S {
                Inner inner;
            }

            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            void put(int* p, int v) {
                *p = v;
            }

            int f() {
                S s = S(Inner(one()));
                int* p = &s.inner.x;
                put(p, ninetyNine());
                return *p + s.inner.x;
            }

            unittest {
                assert(f() == 198);
            }
        });
    }
}

// The class
// sibling of `pointer.structFieldWrittenDirectlyIsVisibleThroughEarlierPointer`
// one level deeper, mirroring `pointer.
// addressOfNestedStructFieldWriteThroughUpdatesField`'s shape but with a
// class RECEIVER instead of a struct one -- `inner` is a (non-union) struct
// FIELD of class `C`, and `x` is a scalar field of `inner`. Other backends
// omitted per the omit-don't-pin convention, matching the other class
// fixtures' own backend set.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws its own unrelated \"Unsupported type in bytecode core: Inner\" for this shape, not a wrong value"),
)) {
    @("pointer.nestedClassStructFieldWrittenDirectlyIsVisibleThroughEarlierPointer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
                int y;
            }

            class C {
                Inner inner;
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
                C c = new C();
                c.inner.x = one();
                c.inner.y = two();
                int* p = &c.inner.x;
                c.inner.x = ninetyNine();
                assert(*p == 99);
            }
        });
    }
}

// Write-through-pointer follow-up: the opposite direction of `pointer.
// nestedClassStructFieldWrittenDirectlyIsVisibleThroughEarlierPointer` above
// -- write THROUGH `&c.inner.x`, then read `c.inner.x` directly -- mirroring
// `pointer.addressOfNestedStructFieldWriteThroughUpdatesField`'s shape but
// with a class RECEIVER instead of a struct one. Other backends omitted per
// the omit-don't-pin convention, matching the other class fixtures' own
// backend set.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws its own unrelated \"Unsupported type in bytecode core: Inner\" for this shape, not a wrong value"),
)) {
    @("pointer.nestedClassStructFieldWrittenThroughPointerIsVisibleDirectly." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            class C {
                Inner inner;
            }

            int seed() {
                return 7;
            }

            unittest {
                C c = new C();
                c.inner.x = seed();
                int* p = &c.inner.x;
                *p = 5;

                assert(c.inner.x == 5);
            }
        });
    }
}

// Cross-frame follow-up: the
// nested-class-struct-field sibling of `pointer.
// classArrayFieldWriteThroughPointerInCalleeIsVisibleToCaller` above. The
// caller takes `&c.inner.x` (promoting a `classCells` entry and a
// `nestedClassStructFieldPointerVariables`/`...OuterFieldIndices`/
// `...InnerFieldIndices` reverse-lookup entry in the CALLER's own frame),
// then passes the pointer into a callee that writes through it. The callee's
// own child `Walker` dupes `classCells` (so the cell's bytes are shared) but,
// before this slice, never duped the reverse-lookup maps themselves, so the
// callee's `writeThroughNestedClassStructFieldPointer` reverse-lookup missed
// and the write fell through to the `fieldSnapshotAllocationIds` refusal
// check (also duped) instead of aliasing. SystemLinker is the oracle;
// Bytecode omitted per the omit-Bytecode convention.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "throws its own unrelated \"Unsupported type in bytecode core: Inner\" for this shape, not a wrong value"),
)) {
    @("pointer.nestedClassStructFieldWriteThroughPointerInCalleeIsVisibleToCaller." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            class C {
                Inner inner;
            }

            int one() {
                return 1;
            }

            int ninetyNine() {
                return 99;
            }

            void put(int* p, int v) {
                *p = v;
            }

            int f() {
                C c = new C();
                c.inner.x = one();
                int* p = &c.inner.x;
                put(p, ninetyNine());
                return *p + c.inner.x;
            }

            unittest {
                assert(f() == 198);
            }
        });
    }
}

// `promoteArrayNestedStructFieldCell`
// evaluated `index.e2` itself (to seed the
// `arrayNestedStructFieldPointer*ElementIndices` reverse-lookup entry), then
// `addressOfExpression`'s `DotVarExp` branch unconditionally called
// `runExpression(dot)` to build the pointer's boxed snapshot -- re-running
// the WHOLE `a[i++].inner.x` chain, including `i++` a second time. A
// side-effecting index (`i++`) therefore ran twice: once inside the promote
// call, once again building the snapshot. SystemLinker's `p` aliases real
// storage and evaluates the index expression exactly once. Other backends
// omitted per the omit-don't-pin convention (unconfirmed there).
static foreach (backend; Matrix!()) {
    @("pointer.arrayNestedStructFieldIndexWithSideEffectEvaluatedOnce." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner {
                int x;
            }

            struct S {
                Inner inner;
            }

            unittest {
                S[] a = [S(Inner(1)), S(Inner(2))];
                int i = 0;
                auto p = &a[i++].inner.x;
                assert(i == 1);
            }
        });
    }
}

// Gap fixture, not a fix (`ai/plans/value.md`'s Cell coherence "Known gaps"
// list): `mid.leaf` and `aliasLeaf` are two live bindings to the SAME `Leaf`
// identity. `mid.leaf.value = mark(1)` is a deep field-chain write reached
// through `mid`'s own frame slot, which correctly refreshes the identity-
// keyed object body the native frame mirror mirrors into (`classObjectTable`,
// `impl.d`'s `mirrorClassToFrame`/`writeClassBody`) -- but `aliasLeaf`'s OWN
// boxed local (`locals[]`, keyed per VARIABLE, not per identity) is never
// refreshed, since only a var's own promoted cell or direct write path
// touches its `locals[]` entry. `impl.d`'s `classIdentityAliasedByAnotherBinding`
// now declines to mirror or verify a class local whenever another live
// binding boxes the identical identity (own header comment), so reading
// `aliasLeaf` afterward hits the generic unpromoted-local path
// (`assertFrameMirror`), finds no mirror slot to check, and returns
// `aliasLeaf`'s own stale boxed value unmodified -- an ordinary WRONG VALUE
// (`aliasLeaf.value == 0`, not `mark(1)`) rather than the internal
// `AssertError: "class body mirror diverged from boxed local"` this used to
// throw. The fault is still in the boxed AUTHORITY itself (the stale
// `locals[]` copy); the mirror merely no longer crashes trying to verify
// against it. Closing this generally needs every class-typed local's read
// to consult identity-keyed storage instead of its own per-variable boxed
// copy -- exactly the native-layout authority switch (`ai/plans/value.md`
// decision 15/17), so it is frozen new representation-ceiling machinery,
// not a correctness fix to existing boxed machinery. `Bytecode` omitted per
// the omit-don't-pin convention (unconfirmed for this shape, matching the
// other object-graph fixtures' own backend set).
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.diverges,
        "boxed-authority staleness: a deep field-chain write through one " ~
        "alias does not refresh another alias's own cached copy of the " ~
        "same object identity, so aliasLeaf.value reads back 0 instead of " ~
        "mark(1) -- see ai/plans/value.md's Cell coherence known gaps"),
)) {
    @("classField.deepChainWriteThroughOneAliasVisibleThroughAnother." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Leaf {
                int value;
            }

            class Mid {
                Leaf leaf;
            }

            int mark(int seed) {
                return seed * 7 + 3;
            }

            unittest {
                auto leaf = new Leaf();
                auto mid = new Mid();
                mid.leaf = leaf;

                auto aliasLeaf = mid.leaf;

                mid.leaf.value = mark(1);

                assert(aliasLeaf.value == mark(1));
            }
        });
    }
}

// The Interpreter counterpart of the gap fixture above, proving the DECLINE
// rather than the crash it replaced: `impl.d`'s
// `classIdentityAliasedByAnotherBinding` (`mirrorClassToFrame`'s and
// `assertClassFrameMirror`'s shared gate, via `classBodyShapeMatches`) now
// sees `leaf` and `aliasLeaf` as two live top-level bindings to the same
// identity and declines to mirror or verify either one, so reading
// `aliasLeaf` afterward hits the generic unpromoted-local path with no
// mirror slot to check at all, rather than reaching `assertClassBodyValue`'s
// own byte-comparison assert. The interpreted guest program therefore runs
// to completion and fails its OWN `assert(aliasLeaf.value == mark(1))` the
// ordinary way (`0 != 10`, `throwOnTestFailure`'s plain `Exception`) instead
// of dying with `core.exception.AssertError: "class body mirror diverged
// from boxed local"`. Not a `Matrix!()` member (no `SystemLinker`-oracle
// comparison is possible here -- `SystemLinker` passes cleanly, so a
// Matrix fixture would only ever restate the known gap above): a hand-
// written `AliasSeq!(Interpreter)` pin of Interpreter's own actual, still-
// divergent behaviour, per AGENTS.md's characterization-pin convention.
static foreach (backend; AliasSeq!(Interpreter)) {
    @("classField.deepChainWriteThroughOneAliasVisibleThroughAnotherDeclinesRatherThanAsserts." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class Leaf {
                int value;
            }

            class Mid {
                Leaf leaf;
            }

            int mark(int seed) {
                return seed * 7 + 3;
            }

            unittest {
                auto leaf = new Leaf();
                auto mid = new Mid();
                mid.leaf = leaf;

                auto aliasLeaf = mid.leaf;

                mid.leaf.value = mark(1);

                assert(aliasLeaf.value == mark(1));
            }
        }).shouldThrowWithMessage("0 != 10");
    }
}


// A `ref` argument written as an explicit dereference of an address-of binds
// the VARIABLE, not what it points at. The reason this shape is worth its own
// fixture is that DMD hands the call site it verbatim rather than folding it
// back to a bare `VarExp`: `optimize.d`'s `visitPtr` folds `&p` down to a
// `SymOffExp` and then returns at `keepLvalue` (true for a `ref` argument)
// before folding the `PtrExp` away. So the interpreter's own lvalue-place
// composition (`lvalue_place.placeOfLvalue`, reached from `impl.d`'s
// `bindReferenceSlot`) meets a `PtrExp` over a `SymOffExp`, where the
// address-of and the dereference must cancel rather than compose into two
// dereferences of `p`'s slot.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "binds a `ref` argument written `*&p` to what `p` points at rather " ~
        "than to `p` itself"),
)) {
    @("pointer.refArgumentThroughDerefOfAddressOfRebindsTheVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 42;
            }

            void rebind(ref int* q, int* target) {
                q = target;
            }

            unittest {
                int first = seed;
                int second = 99;
                int* p = &first;
                rebind(*&p, &second);
                assert(*p == 99);
                assert(first == 42);
            }
        });
    }
}

// The static-array sibling of the fixture above: `*&buf[2]` carries DMD's
// own already-computed byte offset for element 2 in the `SymOffExp` it folds
// to, which the `ref` bind must apply directly to `buf`'s own storage
// (`ai/plans/value.md`'s Layout authority contract) rather than re-derive as
// an element index.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "binds a `ref` argument written `*&buf[2]` to the array's first " ~
        "element rather than to element 2"),
)) {
    @("pointer.refArgumentThroughDerefOfArrayElementAddressWritesThatElement." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed() {
                return 42;
            }

            void bump(ref int r) {
                r = r + 1;
            }

            unittest {
                int[4] buf;
                buf[2] = seed;
                bump(*&buf[2]);
                assert(buf[2] == 43);
                assert(buf[1] == 0);
                assert(buf[3] == 0);
            }
        });
    }
}

module ut.backends.runner.lang.arrays;


import ut.backends;


/++
    Generic assert message coverage.

    These tests verify expression/value rendering for failed asserts. Array feature
    tests below should not each repeat these same "actual != expected" checks.
+/
static foreach (backend; Matrix!()) {
    @("assertDiagnostic.integerEquality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(42 == 43);
            }
        }).shouldThrowWithMessage("42 != 43");
    }
}

// An array allocation identity uses one allocation-base coordinate across
// frames: a returned cast of an interior parameter must retain that interior
// offset rather than being rebound to the caller's whole allocation.
static foreach (backend; Matrix!()) {
    @("dynamicArray.returnedCastOfInteriorParameterPreservesOffset." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte[] view(byte[] values) {
                return cast(ubyte[]) values;
            }

            unittest {
                byte runtime = 1;
                byte[] a = [runtime, cast(byte) 2];
                ubyte[] whole = cast(ubyte[]) a;
                byte[] s = a[1 .. 2];
                ubyte[] b = view(s);
                b[0] = 9;

                assert(a[0] == 1);
                assert(a[1] == 9);
            }
        });
    }
}

// Reinterpreting a signed-byte slice as `ubyte[]` exposes its stored bits,
// rather than converting each signed value.
static foreach (backend; Matrix!()) {
    @("dynamicArray.castSignedBytesToUbytesPreservesRawBits." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                byte first = 1;
                byte negativeOne = -2;
                byte second = 3;
                byte negativeTwo = -4;
                byte[] signed = [first, second, negativeOne, cast(byte) 5,
                    negativeTwo];
                auto raw = cast(ubyte[]) signed;

                assert(raw[0] == cast(ubyte) 1);
                assert(raw[1] == cast(ubyte) 3);
                assert(raw[2] == cast(ubyte) 254);
                assert(raw[3] == cast(ubyte) 5);
                assert(raw[4] == cast(ubyte) 252);
            }
        });
    }
}

// A same-width scalar array cast is a view over the source storage, so a
// write through the cast result is visible through the source slice.
static foreach (backend; Matrix!()) {
    @("dynamicArray.sameWidthScalarCastPreservesStorageAliasing." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                byte[] signed = [1];
                ubyte[] raw = cast(ubyte[]) signed;
                raw[0] = 2;

                assert(signed[0] == 2);
            }
        });
    }
}

// A whole-value read through the source binding sees writes made through a
// same-width scalar cast view, not the boxed descriptor's stale elements.
static foreach (backend; Matrix!()) {
    @("dynamicArray.sameWidthScalarCastUpdatesWholeSourceValue." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                byte runtime = 1;
                byte[] signed = [runtime];
                ubyte[] raw = cast(ubyte[]) signed;
                raw[0] = 2;

                assert(signed == [cast(byte) 2]);
            }
        });
    }
}

// Assignment of a same-width scalar array cast preserves the same storage
// aliasing as declaration initialization.
static foreach (backend; Matrix!()) {
    @("dynamicArray.assignedSameWidthScalarCastPreservesStorageAliasing." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                byte runtime = 1;
                byte[] a = [runtime];
                ubyte[] b;
                b = cast(ubyte[]) a;
                b[0] = 2;

                assert(a[0] == 2);
            }
        });
    }
}

// Rebinding the source of a same-width scalar-array view must not detach the
// still-live view from the storage it captured before that rebind.
static foreach (backend; Matrix!()) {
    @("dynamicArray.sameWidthScalarCastSurvivesSourceRebind." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void mutate(ubyte[] values) {
                values[0] = 2;
            }

            unittest {
                byte first = 1;
                byte[] a = [first];
                ubyte[] b = cast(ubyte[]) a;
                a = [cast(byte) 3];
                mutate(b);

                assert(b[0] == 2);
                assert(a[0] == 3);
            }
        });
    }
}

// Rebinding a cast-view variable gives that binding a new allocation identity;
// a later cast of the rebound variable must not redirect surviving aliases of
// the old allocation to the new storage.
static foreach (backend; Matrix!()) {
    @("dynamicArray.reboundSameWidthScalarCastDoesNotRedirectOldAliases." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void mutate(ubyte[] values) {
                values[0] = 9;
            }

            unittest {
                byte first = 1;
                byte[] a = [first];
                ubyte[] b = cast(ubyte[]) a;
                ubyte[] c = b;
                b = [cast(ubyte) 3];
                byte[] d = cast(byte[]) b;
                mutate(c);

                assert(a[0] == 9);
                assert(b[0] == 3);
                assert(c[0] == 9);
                assert(d[0] == 3);
            }
        });
    }
}

// Passing an unbound same-width scalar array cast directly as a slice
// argument preserves the source storage alias.
static foreach (backend; Matrix!()) {
    @("dynamicArray.sameWidthScalarCastArgumentPreservesStorageAliasing." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void mutate(ubyte[] values) {
                values[0] = 2;
            }

            unittest {
                byte runtime = 1;
                byte[] values = [runtime];
                mutate(cast(ubyte[]) values);

                assert(values[0] == 2);
            }
        });
    }
}

// Passing an interior slice of a same-width scalar-array view preserves that
// slice's offset and length instead of rebinding the callee to the whole
// source allocation.
static foreach (backend; Matrix!()) {
    @("dynamicArray.interiorSameWidthScalarCastSliceArgumentPreservesBounds." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void mutate(ubyte[] values) {
                values[0] = 9;
            }

            unittest {
                byte first = 1;
                byte[] a = [first, cast(byte) 2];
                ubyte[] b = cast(ubyte[]) a;
                ubyte[] c = b[1 .. 2];
                mutate(c);

                assert(a[0] == 1);
                assert(a[1] == 9);
            }
        });
    }
}

// Returning an unbound same-width scalar array cast preserves the source
// storage alias after the callee frame has gone away.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a mutable module variable"),
)) {
    @("dynamicArray.sameWidthScalarCastReturnPreservesStorageAliasing." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            byte[] a;

            ubyte[] view() {
                return cast(ubyte[]) a;
            }

            unittest {
                byte runtime = 1;
                a = [runtime];
                ubyte[] b = view();
                b[0] = 2;

                assert(a[0] == 2);
            }
        });
    }
}

// Assigning a returned same-width scalar-array view preserves its source
// storage alias just as declaration initialization does.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a mutable module variable"),
)) {
    @("dynamicArray.assignedReturnedSameWidthScalarCastPreservesStorageAliasing." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            byte[] a;

            ubyte[] view() {
                return cast(ubyte[]) a;
            }

            unittest {
                byte runtime = 1;
                a = [runtime];
                ubyte[] b;
                b = view();
                b[0] = 2;

                assert(a[0] == 2);
            }
        });
    }
}

// `a ~= append()` where `a` is a module-level array and `append` itself
// appends to `a` by name: the outer append's own descriptor must reflect
// whatever `append` already committed to `a`'s real storage, not a snapshot
// taken before `append` ran. SystemLinker is the oracle.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a mutable module variable"),
    Omit!(Interpreter, Because.refusal,
        "Unsupported interpreter array append target."),
)) {
    @("dynamicArray.moduleAppendSurvivesReentrantAppendDuringRhsCall." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            byte[] a;

            byte append() {
                byte runtime = 7;
                a ~= runtime;
                return 9;
            }

            unittest {
                a ~= append();

                assert(a.length == 2);
                assert(a[0] == 7);
                assert(a[1] == 9);
            }
        });
    }
}

// `a ~= append()` where `a` is a module-level array, `append` returns a
// *whole array* (`CatAssignExp`, not the single-element `CatElemAssignExp`
// case above), and `append` itself appends to `a` by name: the outer
// concatenation's own descriptor must reflect whatever `append` already
// committed to `a`'s real storage, not a snapshot taken before `append` ran.
// SystemLinker is the oracle.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a mutable module variable"),
    Omit!(Interpreter, Because.refusal,
        "Unsupported interpreter array append target."),
)) {
    @("dynamicArray.moduleConcatenationSurvivesReentrantAppendDuringRhsCall." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            byte[] a;

            byte[] append() {
                byte runtime = 7;
                a ~= runtime;
                byte other = 9;
                return [other];
            }

            unittest {
                a ~= append();

                assert(a.length == 2);
                assert(a[0] == 7);
                assert(a[1] == 9);
            }
        });
    }
}

// `gp.arr ~= x` where `gp` is a module-level struct and `arr` is one of its
// dynamic-array fields: the field's own slice descriptor lives inside the
// struct's whole-block dataseg copy, so its writeback must land at the
// field's own module offset, not silently drop the append. SystemLinker is
// the oracle.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read or write dataseg (__gshared/static) storage"),
)) {
    @("dynamicArray.moduleStructFieldAppendWritesBackToModule." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct P { int x; byte[] arr; }
            P gp;

            unittest {
                gp.x = 9;
                byte runtime = cast(byte) (40 + 2);
                gp.arr ~= runtime;

                assert(gp.x == 9);
                assert(gp.arr.length == 1);
                assert(gp.arr[0] == 42);
            }
        });
    }
}

// A module-level dynamic array with a non-null array-literal initializer
// (`int[] arr = [1, 2, 3];`): `moduleDynamicArrayVariableOrNull` used to
// treat this the same as no initializer at all (a plain array literal
// parses as an `ArrayInitializer`, not the `ExpInitializer`
// `moduleVariableHasDefaultInitializer` recognised), so `arr` read back a
// zero-length null slice instead of its declared contents. `Ctfe` cannot
// read dataseg storage at all; `Interpreter` and `LLVMJit` have the same
// gap, unconfirmed/unfixed here.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read dataseg (__gshared/static) storage"),
    Omit!(Interpreter, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("dynamicArray.moduleArrayLiteralInitializer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[] arr = [1, 2, 3];

            int sum() {
                return arr[0] + arr[1] + arr[2];
            }

            unittest {
                // First touch is from a lazily-compiled callee, not the
                // entry itself; it must still see the initialised contents.
                assert(sum() == 6);

                assert(arr.length == 3);
                assert(arr[0] == 1);
                assert(arr[1] == 2);
                assert(arr[2] == 3);

                arr[0] = 99;
                assert(arr[0] == 99);
                arr ~= 4;
                assert(arr.length == 4);
                assert(arr[3] == 4);
            }
        });
    }
}

// The array-of-arrays-element sibling of the fixture above
// (`int[][] arr = [[1, 2], [3, 4]];`): `moduleDynamicArrayLiteralInitializerBytes`
// declined any `elementIsArray` shape outright, so `arr` fell all the way
// through `moduleDynamicArrayVariableOrNull` to "declined" and the variable
// was never registered as dataseg storage at all.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read dataseg (__gshared/static) storage"),
    Omit!(Interpreter, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("dynamicArray.moduleArrayOfArraysLiteralInitializer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[][] arr = [[1, 2], [3, 4]];

            int sum() {
                return arr[0][0] + arr[0][1] + arr[1][0] + arr[1][1];
            }

            unittest {
                assert(sum() == 10);

                assert(arr.length == 2);
                assert(arr[0][0] == 1);
                assert(arr[0][1] == 2);
                assert(arr[1][0] == 3);
                assert(arr[1][1] == 4);

                auto row = arr[0];
                row[0] = 99;
                assert(arr[0][0] == 99);
            }
        });
    }
}

// `arr[0].length` where `arr` is a module-level `int[][]`:
// `compileArrayLength` used to call `dynamicArrayDescriptor` ->
// `dynamicArrayDescriptorOrNull` directly, whose `IndexExp` branch
// (`innerArrayDescriptor`) only resolves an array-of-arrays base that is
// either a known local (`_dynamicArrayLocals`) or a struct/class-field
// `DotVarExp` -- never a bare module-level `VarExp`, since a module
// dynamic array is never inserted into `_dynamicArrayLocals`. This threw
// "Unsupported dynamic array access in bytecode core: arr[0]" even though
// the sibling shape `arr[0][0]` (a further index, not `.length`) already
// worked, via `tryDynamicArrayIndex`'s own fallback to
// `indexedArrayDescriptor`, which materialises *any* array-typed
// expression generically through `compileDynamicArrayInto`. Fixed by
// giving `compileArrayLength` that same fallback, scoped to this one call
// site rather than `dynamicArrayDescriptor` itself (nine other call
// sites) to avoid touching `innerArrayDescriptor`'s own resolution at all.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read dataseg (__gshared/static) storage"),
    Omit!(Interpreter, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("dynamicArray.moduleArrayOfArraysElementLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[][] arr = [[1, 2], [3, 4]];

            unittest {
                assert(arr[0].length == 2);
            }
        });
    }
}

// The three-levels-deep sibling (`m[0][0].length`): confirms the fix
// generalises through a second index rather than only unwrapping one
// level, without needing any change to `innerArrayDescriptor` itself.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read dataseg (__gshared/static) storage"),
    Omit!(Interpreter, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("dynamicArray.moduleArrayOfArraysOfArraysElementLength." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[][][] m = [[[1, 2], [3, 4]], [[5, 6]]];

            unittest {
                assert(m[0][0].length == 2);
                assert(m[1][0].length == 2);
            }
        });
    }
}

// The local-variable counterpart: this shape already worked before the
// fix above, since a local's array-of-arrays base is tracked in
// `_dynamicArrayLocals` and `innerArrayDescriptor` already resolved it
// directly; kept here as an explicit regression guard alongside the
// module-level fix.
static foreach (backend; Matrix!()) {
    @("dynamicArray.localArrayOfArraysElementLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[][] arr = [[1, 2], [3, 4]];
                assert(arr[0].length == 2);
            }
        });
    }
}

// The two-levels-of-nesting sibling of the fixture above
// (`int[][][] m = [[[1, 2], [3, 4]], [[5, 6]]];`):
// `moduleDynamicArrayLiteralInitializerBytes` used to hardcode its
// recursive call's `elementIsArray` to `false`, so it only ever unwrapped
// exactly one level of array-of-arrays nesting before falling into the
// plain-scalar branch -- a middle-level row here (itself an `int[][]`, not
// a leaf of scalars) failed that branch's `isIntegerExp`/`isRealExp` checks
// and declined the whole array, so `m` fell all the way through
// `moduleDynamicArrayVariableOrNull` to "declined" and the variable was
// never registered as dataseg storage at all. It now re-derives
// `elementIsArray` from each row's own `Expression.type`, so this keeps
// recursing at any nesting depth.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read dataseg (__gshared/static) storage"),
    Omit!(Interpreter, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("dynamicArray.moduleArrayOfArraysOfArraysLiteralInitializer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[][][] m = [[[1, 2], [3, 4]], [[5, 6]]];

            int sum() {
                return m[0][0][0] + m[0][0][1] + m[0][1][0] + m[0][1][1] +
                    m[1][0][0] + m[1][0][1];
            }

            unittest {
                assert(sum() == 21);

                assert(m.length == 2);
                assert(m[0][0][0] == 1);
                assert(m[0][0][1] == 2);
                assert(m[0][1][0] == 3);
                assert(m[0][1][1] == 4);
                assert(m[1][0][0] == 5);
                assert(m[1][0][1] == 6);

                auto row = m[0][1];
                row[0] = 99;
                assert(m[0][1][0] == 99);
            }
        });
    }
}

// A module-level dynamic array with an *empty* array-literal initializer
// (`int[] arr = [];`): `moduleDynamicArrayLiteralInitializerBytes` used to
// treat a zero-length `elements` array the same as any other shape it
// can't inspect an element from, declining registration entirely (the
// variable fell through `moduleDynamicArrayVariableOrNull` to
// "declined", same as a genuinely unsupported initializer). An empty
// literal is semantically just the default-initialized null/zero-length
// slice, so `moduleDynamicArrayVariableOrNull` now treats it the same as
// no initializer at all: real (empty) storage is registered, and `arr`
// behaves exactly like `int[] arr;` would.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read dataseg (__gshared/static) storage"),
    Omit!(Interpreter, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("dynamicArray.moduleEmptyArrayLiteralInitializer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[] arr = [];

            unittest {
                assert(arr.length == 0);
                assert(arr is null || arr.length == 0);
                arr ~= 1;
                assert(arr.length == 1);
                assert(arr[0] == 1);
            }
        });
    }
}

// The "any non-constant element (e.g. a function call)" case the plan text
// above lists as declined: a `pure`, side-effect-free call like `f()` here
// is trivially CTFEable, and DMD's own frontend semantic pass requires
// every dataseg (module-level, non-`immutable`) initializer to reduce to a
// genuine compile-time constant -- it folds the whole `ArrayLiteralExp`
// element-by-element via CTFE, so by the time our compiler ever inspects
// the initializer, this element is already a plain `IntegerExp(42)`, not a
// `CallExp`. `moduleDynamicArrayLiteralInitializerBytes`'s existing
// `isIntegerExp`/`isRealExp` checks already handle it: no separate
// "non-constant element" support is needed for this shape.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read dataseg (__gshared/static) storage"),
    Omit!(Interpreter, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("dynamicArray.moduleArrayLiteralCtfeableCallElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int f() { return 42; }
            int[] arr = [1, f(), 3];

            unittest {
                assert(arr.length == 3);
                assert(arr[0] == 1);
                assert(arr[1] == 42);
                assert(arr[2] == 3);
            }
        });
    }
}

// The other half of the same finding: a genuinely non-CTFEable call
// (`time` has no available source for the frontend to interpret) is a
// hard compile-time error from the *shared* DMD frontend
// (`quickbite.frontend.compiler`), identical on every backend -- it never
// reaches `moduleDynamicArrayLiteralInitializerBytes` at all, so this is
// not a backend-specific gap either. No `Omit`: the same error fires for
// every backend in the matrix.
static foreach (backend; Matrix!()) {
    @("dynamicArray.moduleArrayLiteralNonCtfeableCallElementIsFrontendError." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            import core.stdc.time: time;
            int f() { return cast(int)(time(null) % 1000000000); }
            int[] arr = [1, f(), 3];

            unittest {
                assert(arr.length == 3);
            }
        }).shouldThrowWithMessage(
            "`time` cannot be interpreted at compile time, because it has " ~
            "no available source code");
    }
}

// The struct-element sibling of the plain-scalar and array-of-arrays
// module literal fixtures above (`Point[] pts = [Point(1, 2), Point(3,
// 4)];`): `moduleDynamicArrayLiteralInitializerBytes` declined any element
// whose leaf `dynamicArrayElementType` was `ScalarType.void_` outright
// (the same tag it uses for a still-declined static-array/delegate
// element), even though a struct element whose own fields are constant
// scalars is a perfectly ordinary compile-time constant DMD's frontend
// already accepts for a module-level `Point[]`. Each element's own
// `StructLiteralExp` fields are now laid out at DMD's own per-field
// offset within the element's slot
// (`moduleDynamicArrayStructLiteralInitializerBytes`), reusing the same
// per-field byte-writing `moduleStructLiteralInitializerBytes` already
// uses for a whole module-level struct variable's default value
// (`writeStructLiteralFieldBytes`).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read dataseg (__gshared/static) storage"),
    Omit!(Interpreter, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("dynamicArray.moduleArrayOfStructsLiteralInitializer." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }
            Point[] pts = [Point(1, 2), Point(3, 4)];

            int sum() {
                return pts[0].x + pts[0].y + pts[1].x + pts[1].y;
            }

            unittest {
                // First touch is from a lazily-compiled callee, not the
                // entry itself; it must still see the initialised contents.
                assert(sum() == 10);

                assert(pts.length == 2);
                assert(pts[0].x == 1);
                assert(pts[0].y == 2);
                assert(pts[1].x == 3);
                assert(pts[1].y == 4);

                pts[0].x = 99;
                assert(pts[0].x == 99);

                auto p = pts[1];
                p.x = 100;
                assert(pts[1].x == 3);
            }
        });
    }
}

// Array-of-arrays structural equality (`int[][] == int[][]`): DMD's real
// `__equals` lowering recurses into each row's content, so two separately
// heap-allocated but content-equal arrays-of-arrays must compare equal --
// a raw byte compare of the outer descriptor would instead compare each
// row's `.ptr`, which differs across the two separate literal allocations
// below.
static foreach (backend; Matrix!()) {
    @("dynamicArray.arrayOfArraysEqualityIsStructural." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[][] a = [[1, 2], [3, 4]];
                int[][] b = [[1, 2], [3, 4]];
                assert(a == b);
                assert(!(a != b));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assertDiagnostic.arrayOfArraysSameLengthDifferentContent." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[][] a = [[1, 2], [3, 4]];
                int[][] b = [[1, 2], [3, 99]];
                assert(a == b);
            }
        }).shouldThrowWithMessage("[[1, 2], [3, 4]] != [[1, 2], [3, 99]]");
    }
}

static foreach (backend; Matrix!()) {
    @("assertDiagnostic.arrayOfArraysDifferentInnerLength." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[][] a = [[1, 2], [3, 4]];
                int[][] b = [[1, 2], [3]];
                assert(a == b);
            }
        }).shouldThrowWithMessage("[[1, 2], [3, 4]] != [[1, 2], [3]]");
    }
}

// Same structural-equality requirement as `arrayOfArraysEqualityIsStructural`
// above, but two levels of nesting deep (`int[][][]`): DMD's real `__equals`
// recurses all the way down regardless of depth, so `Op.sliceEqualNested`
// must too. `b` is built entirely through separate `~=` appends at every
// level (outer, middle, and row) rather than a literal, so every row and
// sub-row it holds is a distinct heap allocation from `a`'s -- a bug that
// compared by identity/descriptor-bytes at any level (not just the
// outermost) would wrongly report these unequal.
static foreach (backend; Matrix!()) {
    @("dynamicArray.arrayOfArraysOfArraysEqualityIsStructural." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[][][] a = [[[1, 2], [3, 4]], [[5, 6], [7, 8]]];

                int[][] row0;
                row0 ~= [1, 2];
                row0 ~= [3, 4];
                int[][] row1;
                row1 ~= [5, 6];
                row1 ~= [7, 8];
                int[][][] b;
                b ~= row0;
                b ~= row1;

                assert(a == b);
                assert(!(a != b));
            }
        });
    }
}

// The assert-diagnostic rendering sibling of the test above, at the same
// three-level depth: a difference at the innermost row (not the outermost
// or middle level) must still be detected and rendered -- a bug that
// generalised the depth check but not the recursion itself (e.g. stopping
// one level too shallow) would either wrongly pass or mis-render this.
static foreach (backend; Matrix!()) {
    @("assertDiagnostic.arrayOfArraysOfArraysSameLengthDifferentInnerContent." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[][][] a = [[[1, 2], [3, 4]]];
                int[][][] b = [[[1, 2], [3, 99]]];
                assert(a == b);
            }
        }).shouldThrowWithMessage("[[[1, 2], [3, 4]]] != [[[1, 2], [3, 99]]]");
    }
}

// Same structural-equality requirement as `arrayOfArraysEqualityIsStructural`
// above, but the row itself is a static array (`int[2][]`, a dynamic array
// whose element is `Tsarray`, not `Tarray`): this VM heap-boxes such a row
// behind its own 16-byte slice descriptor the same way it boxes an `int[]`
// row, but the leaf-element sizing still needs to terminate the walk at
// the `Tsarray` and size its own elements, not the `Tsarray`'s full byte
// size -- a fix generalizing only the `Tarray`-row walk could still get
// this wrong (e.g. by trying to size or recurse into the `Tsarray` row
// itself instead of terminating there).
// `b` is built entirely through separate `~=` appends, so its rows are a
// distinct heap allocation from `a`'s.
static foreach (backend; Matrix!()) {
    @("dynamicArray.arrayOfStaticArraysEqualityIsStructural." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[2][] a;
                a ~= [1, 2];
                a ~= [3, 4];

                int[2][] b;
                b ~= [1, 2];
                b ~= [3, 4];

                assert(a == b);
                assert(!(a != b));
            }
        });
    }
}

// The not-equal sibling of the test above, guarding against a fix that
// makes `int[2][] == int[2][]` vacuously true instead of comparing content.
static foreach (backend; Matrix!()) {
    @("dynamicArray.arrayOfStaticArraysInequalityIsStructural." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[2][] a;
                a ~= [1, 2];
                a ~= [3, 4];

                int[2][] b;
                b ~= [1, 2];
                b ~= [3, 99];

                assert(!(a == b));
                assert(a != b);
            }
        });
    }
}

// The assert-diagnostic rendering sibling of the two tests above: exercises
// `tryArrayComparisonAssert`'s shared `emitNestedArrayEqual` path (the same
// helpers backing the plain `==` operator) for the `Tsarray`-row shape.
static foreach (backend; Matrix!()) {
    @("assertDiagnostic.arrayOfStaticArraysSameLengthDifferentContent." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[2][] a;
                a ~= [1, 2];
                a ~= [3, 4];

                int[2][] b;
                b ~= [1, 2];
                b ~= [3, 99];

                assert(a == b);
            }
        }).shouldThrowWithMessage("[[1, 2], [3, 4]] != [[1, 2], [3, 99]]");
    }
}

static foreach (backend; Matrix!()) {
    @("assertDiagnostic.characterEquality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert('e' == 'f');
            }
        }).shouldThrowWithMessage("'e' != 'f'");
    }
}

static foreach (backend; Matrix!()) {
    @("assertDiagnostic.booleanEquality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                assert(true == false);
            }
        }).shouldThrowWithMessage("true != false");
    }
}

static foreach (backend; Matrix!()) {
    @("assertDiagnostic.arrayElementMismatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] a = [1, 2, 3];
                ubyte[] b = [1, 2, 4];

                assert(a[] == b[]);
            }
        }).shouldThrowWithMessage("[1, 2, 3] != [1, 2, 4]");
    }
}

static foreach (backend; Matrix!()) {
    @("assertDiagnostic.arrayLengthMismatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] a = [1, 2];
                ubyte[] b = [1, 2, 3];

                assert(a[] == b[]);
            }
        }).shouldThrowWithMessage("[1, 2] != [1, 2, 3]");
    }
}


/++
    Dynamic array basics.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.lengthCases." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] uninitialized;
                ubyte[] empty = [];
                ubyte[] nonEmpty = [1, 2, 3];

                assert(uninitialized.length == 0);
                assert(empty.length == 0);
                assert(nonEmpty.length == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.literalElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] literal = [1, 2];

                int a = 10;
                int b = 20;
                int[] runtime = [a, b];

                assert(literal[0] == 1);
                assert(literal[1] == 2);
                assert(runtime[0] == 10);
                assert(runtime[1] == 20);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.ubyteLiteralTruncatesElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int value = 258;
                ubyte[] arr = [cast(ubyte) value];

                assert(arr[0] == 2);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.indexReadWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x00u];

                assert(values[0] == 0x29u);

                values[1] = 0x2au;

                assert(values[1] == 0x2au);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.postIncrementIndex." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [0x29u, 0x2au];
                size_t index = 0;

                assert(values[index++] == 0x29u);
                assert(index == 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.mutableStringLiteralCopiesDoNotShareWrites." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char[2] first = "ab";
                first[0] = 'z';

                char[2] second = "ab";

                assert(second[0] == 'a');
            }
        });
    }
}


/++
    Append and concatenation.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.localAppend." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values;
                ubyte value = 42;

                values ~= value;

                assert(values.length == 1);
                assert(values[0] == value);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.appendToNonEmptyArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                auto values = [0x2au];

                values ~= 0x2bu;

                assert(values.length == 2);
                assert(values[0] == 0x2au);
                assert(values[1] == 0x2bu);
            }
        });
    }
}

// `int[3] row = arr[0];` where `arr` is `int[3][]` (a dynamic array of
// heap-boxed static-array rows, `elementIsArray`'s representation: each row
// is its own heap block addressed through a 16-byte slice descriptor).
// `tryDynamicArrayIndex` materialises `arr[0]` as that row's own 16-byte
// descriptor (pointer + length), needed as-is for further chained indexing
// (`arr[0][j]`); `compileStaticArrayValueInto`'s generic `Tsarray`-typed-
// source fallback used to block-copy those raw descriptor bytes straight
// into `row`'s inline frame slot instead of the row's actual content -- a
// silent wrong-answer bug (confirmed: read `947234800` instead of `1`), not
// a diagnostic. Fixed by detecting this exact shape first and dereferencing
// through the row's own heap pointer (the same `indexLoad` mechanism
// `loadDynamicArrayElement` itself uses to read one element out of a
// descriptor) rather than copying the descriptor's raw bytes. This shape is
// not module-specific: a local `T[N][]` hits the identical
// `tryDynamicArrayIndex` code path and was equally wrong before this fix,
// simply unexercised by any prior fixture (see the local counterpart
// below).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read dataseg (__gshared/static) storage"),
    Omit!(Interpreter, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("dynamicArray.moduleStaticArrayOfArraysRowValueRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[3][] arr = [[1, 2, 3], [4, 5, 6]];

            unittest {
                int[3] row = arr[0];
                assert(row[0] == 1);
                assert(row[1] == 2);
                assert(row[2] == 3);

                int[3] second = arr[1];
                assert(second[0] == 4);
                assert(second[1] == 5);
                assert(second[2] == 6);
            }
        });
    }
}

// The local-variable counterpart of the fixture above: confirms the fix is
// not module-specific (`tryDynamicArrayIndex`'s row-descriptor shape is the
// same for a local base) and stands as an explicit regression guard.
static foreach (backend; Matrix!()) {
    @("dynamicArray.localStaticArrayOfArraysRowValueRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[3][] arr = [[1, 2, 3], [4, 5, 6]];

                int[3] row = arr[0];
                assert(row[0] == 1);
                assert(row[1] == 2);
                assert(row[2] == 3);

                int[3] second = arr[1];
                assert(second[0] == 4);
                assert(second[1] == 5);
                assert(second[2] == 6);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.appendStaticArrayRow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[2][] rows;
                rows ~= [seed(1), seed(2)];
                rows ~= [seed(3), seed(4)];

                assert(rows.length == 2);
                assert(rows[0][0] == 1);
                assert(rows[0][1] == 2);
                assert(rows[1][0] == 3);
                assert(rows[1][1] == 4);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.concatenatesArrayOfArrays." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[][] outer;
                outer ~= [seed(1), seed(2)];
                int[][] other;
                other ~= [seed(3), seed(4)];

                outer ~= other;

                assert(outer.length == 2);
                assert(outer[0][0] == 1);
                assert(outer[0][1] == 2);
                assert(outer[1][0] == 3);
                assert(outer[1][1] == 4);
            }
        });
    }
}

// `outer[0]`'s own sub-slice assignment rhs is a plain dynamic-array
// variable (`rhs`), not itself sliced (`rhs[]`) or a literal -- the general
// case `compileSourceSlice` must resolve by compiling `rhs` as an ordinary
// expression and reusing its own slice descriptor.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "assignment target is a slice of an indexed element"),
)) {
    @("dynamicArray.subSliceAssignmentOntoArrayOfArraysElementFromPlainVariable." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[][] outer;
                outer ~= [seed(1), seed(2), seed(3)];
                int[] rhs = [seed(7), seed(8)];

                outer[0][0 .. 2] = rhs;

                assert(outer[0][0] == 7);
                assert(outer[0][1] == 8);
                assert(outer[0][2] == 3);
            }
        });
    }
}

// Sub-slice assignment whose element is itself a 16-byte slice descriptor
// (`outer[lo..hi] = otherOuter` for `T[][]`, copying whole row descriptors
// across multiple rows), not a single row's scalar contents.
static foreach (backend; Matrix!()) {
    @("dynamicArray.subSliceAssignmentWithArrayElementsAcrossMultipleRows." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[][] outer;
                outer ~= [seed(1), seed(2)];
                outer ~= [seed(3), seed(4)];
                int[][] other;
                other ~= [seed(7), seed(8)];
                other ~= [seed(9), seed(10)];

                outer[0 .. 2] = other;

                assert(outer[0][0] == 7);
                assert(outer[0][1] == 8);
                assert(outer[1][0] == 9);
                assert(outer[1][1] == 10);
            }
        });
    }
}

// Sub-slice assignment whose element is a 16-byte struct (not a slice
// descriptor): each element must copy its full width rather than the
// scalar width a struct-blind element-size computation would fall back to.
static foreach (backend; Matrix!()) {
    @("dynamicArray.subSliceAssignmentWithStructElementsAcrossMultipleRows." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                S[] outer;
                outer ~= S(seed(1), seed(2));
                outer ~= S(seed(3), seed(4));
                S[] other;
                other ~= S(seed(7), seed(8));
                other ~= S(seed(9), seed(10));

                outer[0 .. 2] = other;

                assert(outer[0].a == 7);
                assert(outer[0].b == 8);
                assert(outer[1].a == 9);
                assert(outer[1].b == 10);
            }
        });
    }
}

// A dynamic array whose element is a struct wider than 16 bytes (24 bytes):
// appending an element, reading `.length`, and indexing back into it must all
// use the element's real width instead of falling back to a narrower
// fixed-width copy or refusing the operation.
static foreach (backend; Matrix!()) {
    @("dynamicArray.appendStructElementWiderThan16Bytes." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
                long c;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                S[] outer;
                outer ~= S(seed(1), seed(2), seed(3));
                outer ~= S(seed(4), seed(5), seed(6));

                assert(outer.length == 2);
                assert(outer[0].a == 1);
                assert(outer[0].b == 2);
                assert(outer[0].c == 3);
                assert(outer[1].a == 4);
                assert(outer[1].b == 5);
                assert(outer[1].c == 6);
            }
        });
    }
}

// A dynamic array whose element is a struct wider than 16 bytes (24 bytes):
// whole-array concatenation (`~=`) must copy the right-hand array's elements
// at their real width instead of falling back to a narrower fixed-width copy
// or refusing the operation.
static foreach (backend; Matrix!()) {
    @("dynamicArray.concatenationAssignmentWithStructElementsWiderThan16Bytes."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
                long c;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                S[] outer;
                outer ~= S(seed(1), seed(2), seed(3));

                S[] other;
                other ~= S(seed(4), seed(5), seed(6));
                other ~= S(seed(7), seed(8), seed(9));

                outer ~= other;

                assert(outer.length == 3);
                assert(outer[0].a == 1);
                assert(outer[0].b == 2);
                assert(outer[0].c == 3);
                assert(outer[1].a == 4);
                assert(outer[1].b == 5);
                assert(outer[1].c == 6);
                assert(outer[2].a == 7);
                assert(outer[2].b == 8);
                assert(outer[2].c == 9);
            }
        });
    }
}

// A dynamic array whose element is a struct wider than 16 bytes (24 bytes):
// indexed assignment (`outer[0] = ...`) must write the element's full width
// into its own backing slot instead of falling back to a narrower
// fixed-width copy or refusing the assignment.
static foreach (backend; Matrix!()) {
    @("dynamicArray.indexAssignmentWithStructElementsWiderThan16Bytes." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
                long c;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                S[] outer;
                outer ~= S(seed(1), seed(2), seed(3));
                outer ~= S(seed(4), seed(5), seed(6));

                outer[0] = S(seed(7), seed(8), seed(9));

                assert(outer[0].a == 7);
                assert(outer[0].b == 8);
                assert(outer[0].c == 9);
                assert(outer[1].a == 4);
                assert(outer[1].b == 5);
                assert(outer[1].c == 6);
            }
        });
    }
}

// A class instance's static-array field, viewed as a dynamic array
// (`c.arr[]`), whose element is a struct wider than 16 bytes (24 bytes): each
// element read through the view must use the element's real width instead of
// falling back to a zero-width read.
static foreach (backend; Matrix!()) {
    @("dynamicArray.classStaticArrayFieldViewWithStructElementsWiderThan16Bytes."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
                long c;
            }

            class C {
                S[2] arr;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                auto c = new C();
                c.arr[0] = S(seed(1), seed(2), seed(3));
                c.arr[1] = S(seed(4), seed(5), seed(6));

                auto view = c.arr[];

                assert(view.length == 2);
                assert(view[0].a == 1);
                assert(view[0].b == 2);
                assert(view[0].c == 3);
                assert(view[1].a == 4);
                assert(view[1].b == 5);
                assert(view[1].c == 6);
            }
        });
    }
}

// A static array whose element is a struct wider than 16 bytes (24 bytes):
// sub-slice assignment must copy each element's full width instead of
// falling back to a narrower fixed-width copy or refusing the assignment.
static foreach (backend; Matrix!()) {
    @("staticArray.subSliceAssignmentWithStructElementsWiderThan16Bytes." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
                long c;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                S[2] outer;
                outer[0] = S(seed(1), seed(2), seed(3));
                outer[1] = S(seed(4), seed(5), seed(6));
                S[2] other;
                other[0] = S(seed(7), seed(8), seed(9));
                other[1] = S(seed(10), seed(11), seed(12));

                outer[0 .. 2] = other[];

                assert(outer[0].a == 7);
                assert(outer[0].b == 8);
                assert(outer[0].c == 9);
                assert(outer[1].a == 10);
                assert(outer[1].b == 11);
                assert(outer[1].c == 12);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.refParameterAppend." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void append(ref ubyte[] values, ubyte value) {
                values ~= value;
            }

            unittest {
                ubyte[] values;
                ubyte value = 42;

                append(values, value);

                assert(values.length == 1);
                assert(values[0] == value);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.concatenation." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] left = [first];
                ubyte[] right = [second];

                const combined = left ~ right;

                assert(combined.length == 2);
                assert(combined[0] == first);
                assert(combined[1] == second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.localConcatenationAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte[] values = [cast(ubyte) 1];
                ubyte[] chunk = [cast(ubyte) 7, cast(ubyte) 42];

                values ~= chunk;

                assert(values.length == 3);
                assert(values[0] == 1);
                assert(values[1] == 7);
                assert(values[2] == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.elementConcatenatesWithArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte value(ubyte seed) {
                return cast(ubyte)(seed + 1);
            }

            unittest {
                ubyte first = value(9);
                ubyte second = value(first);
                ubyte[] tail = [second];

                const leftElement = first ~ tail;
                const rightElement = tail ~ first;

                assert(leftElement.length == 2);
                assert(leftElement[0] == 10);
                assert(leftElement[1] == 11);

                assert(rightElement.length == 2);
                assert(rightElement[0] == 11);
                assert(rightElement[1] == 10);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.fieldConcatenationAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Writer {
                ubyte[] bytes;
            }

            unittest {
                Writer writer;
                ubyte[] chunk = [cast(ubyte) 7, cast(ubyte) 42];

                writer.bytes ~= chunk;

                assert(writer.bytes.length == 2);
                assert(writer.bytes[0] == 7);
                assert(writer.bytes[1] == 42);
            }
        });
    }
}


/++
    Slices.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.sliceFromRuntimeBounds." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                size_t start = 1;
                size_t stop = values.length;

                const tail = values[start .. stop];

                assert(tail.length == 1);
                assert(tail[0] == second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.nullZeroLengthSlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] values;
                size_t start = values.length;
                size_t stop = start;

                auto slice = values[start .. stop];

                assert(slice.length == 0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.nestedSliceWritesPropagateToOriginalArray." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 4];
                int[] s2 = s[0 .. 2];

                s2[0] = 99;

                assert(a[1] == 99);
            }
        });
    }
}

// The reverse direction of a full-array slice alias: `int[] s = a[];`
// should alias `a`'s storage exactly like `&a[0]` does, so a later direct
// write to `a` is visible through `s` too -- the opposite direction from
// `nestedSliceWritesPropagateToOriginalArray` above (a write through the
// slice, visible in the source). SystemLinker's `s` aliases `a`'s real
// storage, so the direct write to `a` is visible through `s`.
static foreach (backend; Matrix!()) {
    @("dynamicArray.directArrayWriteIsVisibleThroughEarlierFullSlice." ~
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
                int[] s = a[];
                a[0] = ninetyNine();
                assert(s[0] == 99);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.nestedSliceAppendKeepsOriginalArrayTail." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] a = [0, 1, 2, 3, 4];
                int[] s = a[1 .. 3];
                int[] s2 = s[1 .. 2];

                s2 ~= 99;

                assert(a[3] == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.sliceAssignmentUpdatesArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                char[] text = ['a', 'b', 'c', 'd'];
                size_t start = 1;
                size_t stop = start + 2;

                text[start .. stop] = "xy";

                assert(text.length == 4);
                assert(text[0] == 'a');
                assert(text[1] == 'x');
                assert(text[2] == 'y');
                assert(text[3] == 'd');

                int[] values = [10, 11, 12, 13];
                values[start .. stop] = [21, 22];

                assert(values.length == 4);
                assert(values[0] == 10);
                assert(values[1] == 21);
                assert(values[2] == 22);
                assert(values[3] == 13);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.partialSliceAssignmentBroadcastsScalarForByteShortAndLongElements." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                byte[] narrow = [
                    cast(byte) seed(1), cast(byte) seed(2),
                    cast(byte) seed(3), cast(byte) seed(4),
                ];
                byte narrowValue = cast(byte) seed(5);
                narrow[1 .. 3] = narrowValue;

                assert(narrow[0] == 1);
                assert(narrow[1] == 5);
                assert(narrow[2] == 5);
                assert(narrow[3] == 4);

                short[] medium = [
                    cast(short) seed(1), cast(short) seed(2),
                    cast(short) seed(3), cast(short) seed(4),
                ];
                short mediumValue = cast(short) seed(6);
                medium[1 .. 3] = mediumValue;

                assert(medium[0] == 1);
                assert(medium[1] == 6);
                assert(medium[2] == 6);
                assert(medium[3] == 4);

                long[] wide = [seed(1), seed(2), seed(3), seed(4)];
                long wideValue = seed(7);
                wide[1 .. 3] = wideValue;

                assert(wide[0] == 1);
                assert(wide[1] == 7);
                assert(wide[2] == 7);
                assert(wide[3] == 4);
            }
        });
    }
}

// A non-basic-type (struct) element wider than 8 bytes: broadcasting a single
// value across a range must copy its full width into every destination
// element, the same way the byte/short/long scalar broadcasts above do.
static foreach (backend; Matrix!()) {
    @("dynamicArray.partialSliceAssignmentBroadcastsStructElementWiderThan8Bytes." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
                long c;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                S[] values = [
                    S(seed(1), seed(2), seed(3)),
                    S(seed(4), seed(5), seed(6)),
                    S(seed(7), seed(8), seed(9)),
                    S(seed(10), seed(11), seed(12)),
                ];

                values[1 .. 3] = S(seed(20), seed(21), seed(22));

                assert(values[0].a == 1);
                assert(values[0].b == 2);
                assert(values[0].c == 3);
                assert(values[1].a == 20);
                assert(values[1].b == 21);
                assert(values[1].c == 22);
                assert(values[2].a == 20);
                assert(values[2].b == 21);
                assert(values[2].c == 22);
                assert(values[3].a == 10);
                assert(values[3].b == 11);
                assert(values[3].c == 12);

                // The broadcast source is also a plain lvalue read out of the
                // same array (not a fresh literal), non-overlapping with the
                // destination range.
                values[0 .. 1] = values[3];

                assert(values[0].a == 10);
                assert(values[0].b == 11);
                assert(values[0].c == 12);
            }
        });
    }
}

// Slice assignment writes existing storage in place, so a slice taken before
// the assignment observes the changed element.
static foreach (backend; Matrix!()) {
    @("dynamicArray.sliceAssignmentIsVisibleThroughEarlierSlice." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int nine() {
                return 9;
            }

            int f() {
                int[] a = [1, 2];
                int[] s = a[0 .. 2];
                a[0 .. 1] = nine();
                return s[0];
            }

            unittest {
                assert(f() == 9);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("dynamicArray.overlappingSliceAssignmentIsRejectedAtCtfe." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1, first + 2];
                size_t targetStart = cast(size_t) seed(1);
                size_t targetStop = cast(size_t) seed(3);
                size_t sourceStart = cast(size_t) seed(0);
                size_t sourceStop = cast(size_t) seed(2);

                values[targetStart .. targetStop] =
                    values[sourceStart .. sourceStop];

                assert(values[1] == first);
            }
        }).shouldThrowWithMessage(
            "overlapping slice assignment `[1..3] = [0..2]`",
        );
    }
}

// Compiled overlapping slice assignment raises druntime's plain
// "Range violation"; the slice-range text is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "see sibling pin above (overlappingSliceAssignmentIsRejectedAtCtfe)"),
)) {
    @("dynamicArray.overlappingSliceAssignmentDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1, first + 2];
                size_t targetStart = cast(size_t) seed(1);
                size_t targetStop = cast(size_t) seed(3);
                size_t sourceStart = cast(size_t) seed(0);
                size_t sourceStop = cast(size_t) seed(2);

                values[targetStart .. targetStop] =
                    values[sourceStart .. sourceStop];

                assert(values[1] == first);
            }
        }).shouldThrowWithMessage("Range violation");
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("dynamicArray.sliceIndexPastLengthDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                size_t start = cast(size_t) value(1);
                size_t stop = cast(size_t) value(3);
                auto slice = values[start .. stop];
                size_t index = cast(size_t) value(3);

                assert(slice[index] == first);
            }
        }).shouldThrowWithMessage("index 3 exceeds array length 2");
    }
}

// Compiled bounds checks raise druntime's ArrayIndexError text; the
// "exceeds array length" wording is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
    Omit!(Interpreter, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
)) {
    @("dynamicArray.sliceIndexPastLengthDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                size_t start = cast(size_t) value(1);
                size_t stop = cast(size_t) value(3);
                auto slice = values[start .. stop];
                size_t index = cast(size_t) value(3);

                assert(slice[index] == first);
            }
        }).shouldThrowWithMessage(
            "index [3] is out of bounds for array of length 2",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("dynamicArray.indexPastLengthDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1];
                size_t index = cast(size_t) value(3);

                assert(values[index] == first);
            }
        }).shouldThrowWithMessage("array index 3 is out of bounds `[0..2]`");
    }
}

// Compiled bounds checks raise druntime's ArrayIndexError text; the
// backtick-range wording is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
    Omit!(Interpreter, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
)) {
    @("dynamicArray.indexPastLengthDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1];
                size_t index = cast(size_t) value(3);

                assert(values[index] == first);
            }
        }).shouldThrowWithMessage(
            "index [3] is out of bounds for array of length 2",
        );
    }
}



/++
    Array allocation, resizing, copying, and operations.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.newUsesRuntimeLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                size_t len = 1;
                ++len;

                auto values = new int[](len);
                values[1] = 42;

                assert(values.length == len);
                assert(values[0] == int.init);
                assert(values[1] == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.newCharArrayUsesRuntimeLengthAndDefaultFill." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            size_t runtimeLength(int seed) {
                return cast(size_t)(seed - 1);
            }

            unittest {
                int seed = 4;
                const len = runtimeLength(seed);

                auto text = new char[](len);

                assert(text.length == 3);
                assert(text[0] == char.init);

                text[1] = cast(char)('a' + seed);

                assert(text[1] == 'e');
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.newMultidimensionalUsesRuntimeLengths." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                size_t rows = 1;
                ++rows;
                size_t cols = 2;
                ++cols;

                auto values = new int[][](rows, cols);
                values[1][2] = 42;

                assert(values.length == rows);
                assert(values[0].length == cols);
                assert(values[1][2] == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.lengthAssignmentResizesArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1];

                values.length = 4;

                assert(values.length == 4);
                assert(values[0] == first);
                assert(values[1] == first + 1);
                assert(values[2] == 0);
                assert(values[3] == 0);

                values.length = 1;

                assert(values.length == 1);
                assert(values[0] == first);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.lengthAssignmentDefaultInitializesStructElements." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Marked {
                int value = 42;
            }

            unittest {
                Marked[] values;
                values.length = 1;

                assert(values[0].value == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.copyFromRuntimeArrayUsesArrayCtor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int seedValue = seed(40);
                int[2] source;
                source[0] = seedValue;
                source[1] = seedValue + 1;

                int[2] copy = source;

                assert(copy[0] == seedValue);
                assert(copy[1] == seedValue + 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.elementWriteWithRuntimeIndexUpdatesRealArray." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[4] values;
                int index = seed(2);
                values[index] = 42;

                assert(values[2] == 42);
                assert(values[0] == 0);
                assert(values[1] == 0);
                assert(values[3] == 0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.multipleElementWritesWithRuntimeIndicesAllPersist." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[4] values;
                int first = seed(1);
                int second = seed(3);

                values[first] = 10;
                values[second] = 20;

                assert(values[0] == 0);
                assert(values[1] == 10);
                assert(values[2] == 0);
                assert(values[3] == 20);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.multidimensionalSliceBlockAssignRepeatsRow." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[2][2] matrix;

                matrix[] = [first, first + 1];

                assert(matrix[0][0] == first);
                assert(matrix[0][1] == first + 1);
                assert(matrix[1][0] == first);
                assert(matrix[1][1] == first + 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.partialSliceAssignmentFromDynamicArrayWritesThroughRealStorage." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                char[8] buff = "--------";
                size_t start = cast(size_t) seed(2);
                size_t stop = start + 2;

                buff[start .. stop] = "xy";

                assert(buff[0] == '-');
                assert(buff[1] == '-');
                assert(buff[2] == 'x');
                assert(buff[3] == 'y');
                assert(buff[4] == '-');
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.structFieldPartialSliceAssignmentWritesThroughRealStorage." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                char[8] bytes;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                Buffer buffer;
                size_t start = cast(size_t) seed(1);
                size_t stop = start + 2;

                buffer.bytes[start .. stop] = "xy";

                assert(buffer.bytes[0] == char.init);
                assert(buffer.bytes[1] == 'x');
                assert(buffer.bytes[2] == 'y');
                assert(buffer.bytes[3] == char.init);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.partialSliceAssignmentFromDynamicArrayOfIntsWritesThroughRealStorage." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[4] values;
                int[] source = [seed(10), seed(20)];
                size_t start = cast(size_t) seed(1);
                size_t stop = start + source.length;

                values[start .. stop] = source[];

                assert(values[0] == 0);
                assert(values[1] == 10);
                assert(values[2] == 20);
                assert(values[3] == 0);
            }
        });
    }
}

// A static array whose element is a 16-byte struct: sub-slice assignment must
// write through the array's own real storage at the struct's full width, the
// same way `staticArray.partialSliceAssignmentFromDynamicArrayOfIntsWritesThroughRealStorage`
// does for a 4-byte scalar element.
static foreach (backend; Matrix!()) {
    @("staticArray.subSliceAssignmentWithStructElementsWritesThroughRealStorage." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                S[2] outer;
                outer[0] = S(seed(1), seed(2));
                outer[1] = S(seed(3), seed(4));
                S[2] other;
                other[0] = S(seed(7), seed(8));
                other[1] = S(seed(9), seed(10));

                outer[0 .. 2] = other[];

                assert(outer[0].a == 7);
                assert(outer[0].b == 8);
                assert(outer[1].a == 9);
                assert(outer[1].b == 10);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.partialSliceAssignmentBroadcastsScalarForByteShortAndLongElements." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                byte[4] narrow;
                byte narrowValue = cast(byte) seed(5);
                narrow[1 .. 3] = narrowValue;

                assert(narrow[0] == 0);
                assert(narrow[1] == 5);
                assert(narrow[2] == 5);
                assert(narrow[3] == 0);

                short[4] medium;
                short mediumValue = cast(short) seed(6);
                medium[1 .. 3] = mediumValue;

                assert(medium[0] == 0);
                assert(medium[1] == 6);
                assert(medium[2] == 6);
                assert(medium[3] == 0);

                long[4] wide;
                long wideValue = seed(7);
                wide[1 .. 3] = wideValue;

                assert(wide[0] == 0);
                assert(wide[1] == 7);
                assert(wide[2] == 7);
                assert(wide[3] == 0);
            }
        });
    }
}

// A non-basic-type (struct) element wider than 8 bytes: broadcasting a single
// value across a range must copy its full width into every destination
// element, the same way the byte/short/long scalar broadcasts above do.
static foreach (backend; Matrix!()) {
    @("staticArray.partialSliceAssignmentBroadcastsStructElementWiderThan8Bytes." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
                long c;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                S[4] values;
                values[0] = S(seed(1), seed(2), seed(3));
                values[1] = S(seed(4), seed(5), seed(6));
                values[2] = S(seed(7), seed(8), seed(9));
                values[3] = S(seed(10), seed(11), seed(12));

                values[1 .. 3] = S(seed(20), seed(21), seed(22));

                assert(values[0].a == 1);
                assert(values[0].b == 2);
                assert(values[0].c == 3);
                assert(values[1].a == 20);
                assert(values[1].b == 21);
                assert(values[1].c == 22);
                assert(values[2].a == 20);
                assert(values[2].b == 21);
                assert(values[2].c == 22);
                assert(values[3].a == 10);
                assert(values[3].b == 11);
                assert(values[3].c == 12);

                // The broadcast source is also a plain lvalue read out of the
                // same array (not a fresh literal), non-overlapping with the
                // destination range.
                values[0 .. 1] = values[3];

                assert(values[0].a == 10);
                assert(values[0].b == 11);
                assert(values[0].c == 12);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("staticArray.overlappingSubSliceAssignmentIsRejectedAtCtfe." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[4] values = [first, first + 1, first + 2, first + 3];
                size_t targetStart = cast(size_t) seed(1);
                size_t targetStop = cast(size_t) seed(4);
                size_t sourceStart = cast(size_t) seed(0);
                size_t sourceStop = cast(size_t) seed(3);

                values[targetStart .. targetStop] =
                    values[sourceStart .. sourceStop];

                assert(values[1] == first);
            }
        }).shouldThrowWithMessage(
            "overlapping slice assignment `[1..4] = [0..3]`",
        );
    }
}

// Compiled overlapping slice assignment raises druntime's plain
// "Range violation"; the slice-range text is CTFE-only, matching the
// sibling dynamicArray pin above.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "see sibling pin above (overlappingSubSliceAssignmentIsRejectedAtCtfe)"),
)) {
    @("staticArray.overlappingSubSliceAssignmentDiagnostic." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[4] values = [first, first + 1, first + 2, first + 3];
                size_t targetStart = cast(size_t) seed(1);
                size_t targetStop = cast(size_t) seed(4);
                size_t sourceStart = cast(size_t) seed(0);
                size_t sourceStop = cast(size_t) seed(3);

                values[targetStart .. targetStop] =
                    values[sourceStart .. sourceStop];

                assert(values[1] == first);
            }
        }).shouldThrowWithMessage("Range violation");
    }
}

// The static-array bounded sub-slice write-through path above went straight
// to an unchecked `pointerSlice` opcode, silently writing past the array's
// own frame storage for an out-of-range upper bound instead of raising the
// `RangeError` compiled D raises. Bounds check it the same way a
// dynamic-array sub-slice does (`Op.subSlice*`'s `validateSubSlice`).
// `Ctfe`'s own compile-time bounds check reports its own divergent wording;
// see the sibling pin below.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin below (Ctfe)"),
)) {
    @("staticArray.partialSliceAssignmentPastLengthThrowsRangeError." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                char[8] buff = "--------";
                size_t start = cast(size_t) seed(6);
                size_t stop = start + 4;

                buff[start .. stop] = "xyzw";
            }
        }).shouldThrowWithMessage(
            "slice [6 .. 10] extends past source array of length 8",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("staticArray.partialSliceAssignmentPastLengthThrowsRangeError." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                char[8] buff = "--------";
                size_t start = cast(size_t) seed(6);
                size_t stop = start + 4;

                buff[start .. stop] = "xyzw";
            }
        }).shouldThrowWithMessage(
            "slice `[6..10]` exceeds array bounds `[0..8]`",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.nestedElementReadWithRuntimeIndicesReadsRealArray." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[3][2] matrix;
                matrix[0][0] = seed(7);
                matrix[1][2] = seed(9);
                int i = seed(1);
                int j = seed(2);

                assert(matrix[i][j] == 9);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.nestedElementWriteWithRuntimeIndexUpdatesRealArray." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[3][2] matrix;
                int i = seed(1);
                matrix[i][2] = seed(42);

                assert(matrix[1][2] == 42);
                assert(matrix[0][0] == 0);
            }
        });
    }
}

// A runtime index past a static array's compile-time-known dimension is
// bounds checked exactly like a dynamic array's runtime index: compiled
// code raises druntime's `ArrayIndexError` text. `Ctfe`'s own bounds check
// uses the divergent backtick-range wording pinned below.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin below (Ctfe)"),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("staticArray.elementWriteWithRuntimeIndexOutOfBoundsDiagnostic." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[4] values;
                int index = seed(7);
                values[index] = 42;
            }
        }).shouldThrowWithMessage(
            "index [7] is out of bounds for array of length 4",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("staticArray.elementWriteWithRuntimeIndexOutOfBoundsDiagnostic." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[4] values;
                int index = seed(7);
                values[index] = 42;
            }
        }).shouldThrowWithMessage("array index 7 is out of bounds `[0..4]`");
    }
}

// A runtime outer index past a nested static array's dimension is bounds
// checked the same way, whether the chain is being read or written.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin below (Ctfe, Interpreter)"),
    Omit!(Interpreter, Because.diverges, "see sibling pin below (Ctfe, Interpreter)"),
)) {
    @("staticArray.nestedElementReadWithRuntimeOuterIndexOutOfBoundsDiagnostic." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[3][2] matrix;
                int i = seed(5);
                int j = seed(1);

                assert(matrix[i][j] == 0);
            }
        }).shouldThrowWithMessage(
            "index [5] is out of bounds for array of length 2",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("staticArray.nestedElementReadWithRuntimeOuterIndexOutOfBoundsDiagnostic." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[3][2] matrix;
                int i = seed(5);
                int j = seed(1);

                assert(matrix[i][j] == 0);
            }
        }).shouldThrowWithMessage("array index 5 is out of bounds `[0..2]`");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin below (Ctfe)"),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("staticArray.nestedElementWriteWithRuntimeOuterIndexOutOfBoundsDiagnostic." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[3][2] matrix;
                int i = seed(5);
                matrix[i][2] = seed(1);
            }
        }).shouldThrowWithMessage(
            "index [5] is out of bounds for array of length 2",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("staticArray.nestedElementWriteWithRuntimeOuterIndexOutOfBoundsDiagnostic." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[3][2] matrix;
                int i = seed(5);
                matrix[i][2] = seed(1);
            }
        }).shouldThrowWithMessage("array index 5 is out of bounds `[0..2]`");
    }
}

// A runtime inner index past a nested static array's dimension is bounds
// checked too, independently of the (in-range) outer index.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin below (Ctfe, Interpreter)"),
    Omit!(Interpreter, Because.diverges, "see sibling pin below (Ctfe, Interpreter)"),
)) {
    @("staticArray.nestedElementReadWithRuntimeInnerIndexOutOfBoundsDiagnostic." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[3][2] matrix;
                int i = seed(0);
                int j = seed(9);

                assert(matrix[i][j] == 0);
            }
        }).shouldThrowWithMessage(
            "index [9] is out of bounds for array of length 3",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("staticArray.nestedElementReadWithRuntimeInnerIndexOutOfBoundsDiagnostic." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[3][2] matrix;
                int i = seed(0);
                int j = seed(9);

                assert(matrix[i][j] == 0);
            }
        }).shouldThrowWithMessage("array index 9 is out of bounds `[0..3]`");
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin below (Ctfe)"),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("staticArray.nestedElementWriteWithRuntimeInnerIndexOutOfBoundsDiagnostic." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[3][2] matrix;
                int i = seed(0);
                int j = seed(9);
                matrix[i][j] = seed(1);
            }
        }).shouldThrowWithMessage(
            "index [9] is out of bounds for array of length 3",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("staticArray.nestedElementWriteWithRuntimeInnerIndexOutOfBoundsDiagnostic." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[3][2] matrix;
                int i = seed(0);
                int j = seed(9);
                matrix[i][j] = seed(1);
            }
        }).shouldThrowWithMessage("array index 9 is out of bounds `[0..3]`");
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.arrayOperationAddsRuntimeElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int second = value(first + 1);
                int[] left = [first, second];
                int[] right = [first + 30, second + 40];
                int[] sums = [0, 0];

                sums[] = left[] + right[];

                assert(sums.length == 2);
                assert(sums[0] == 50);
                assert(sums[1] == 62);
            }
        });
    }
}


/++
    Dynamic array return values.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.returnValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];

                const result = identity(values);

                assert(result.length == 2);
                assert(result[0] == first);
                assert(result[1] == second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.sliceReturnValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte[] tail(ubyte[] values, size_t start, size_t stop) {
                return values[start .. stop];
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];
                size_t start = 1;
                size_t stop = values.length;

                const result = tail(values, start, stop);

                assert(result.length == 1);
                assert(result[0] == second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.indexesCallResult." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            ubyte[] identity(ubyte[] values) {
                return values;
            }

            unittest {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] values = [first, second];

                assert(identity(values)[1] == second);
            }
        });
    }
}


/++
    Associative arrays.
+/
static foreach (backend; Matrix!()) {
    @("assocArray.literalKeepsRuntimeKeysAndValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] values = [first: first + 30, second: second + 30];

                assert(values.length == 2);
                assert(values[first] == 40);
                assert(values[second] == 41);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.literalKeepsLastDuplicateRuntimeKey." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int duplicate = key(10);
                int other = key(11);
                int[int] values = [duplicate: 10, duplicate: 20, other: 30];

                assert(values.length == 2);
                assert(values[duplicate] == 20);
                assert(values[other] == 30);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.keysAndValuesUseRuntimeLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(5);
                int second = value(first + 2);
                int third = value(second + 2);
                int[int] values = [
                    first: first + 18,
                    second: second + 20,
                    third: third + 22,
                ];
                int keySum;
                int valueSum;

                foreach (key; values.keys) {
                    keySum += key;
                }

                foreach (entry; values.values) {
                    valueSum += entry;
                }

                assert(keySum == 21);
                assert(valueSum == 81);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.inFindsRuntimeKey." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int missing = key(second + 1);
                int[int] values = [
                    first: first + 30,
                    second: second + 30,
                ];

                int* found = first in values;
                int* absent = missing in values;

                assert(found !is null);
                assert(*found == 40);
                assert(absent is null);
            }
        });
    }
}

// A key wider than 4 bytes (`long`) must compare its full width, not just
// its low 32 bits.
static foreach (backend; Matrix!()) {
    @("assocArray.longKeyLookupUsesFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long key(long value) {
                return value;
            }

            unittest {
                // Both keys have low 32 bits == 0 (only bits 40/41 set), so a
                // 4-byte-truncated comparison would wrongly collapse them
                // into a single entry.
                long lo = key(1L << 40);
                long hi = key(1L << 41);
                int[long] table;
                table[lo] = 7;
                table[hi] = 9;

                assert((lo in table) !is null);
                assert((hi in table) !is null);
                assert(table[lo] == 7);
                assert(table[hi] == 9);
                assert(table.length == 2);
            }
        });
    }
}

// A `double` key's bytes are its IEEE-754 bit pattern, not a 4-byte `int`
// truncation of them.
static foreach (backend; Matrix!()) {
    @("assocArray.doubleKeyLookupUsesFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            double key(double value) {
                return value;
            }

            unittest {
                // 1.0 and 2.0 have IEEE-754 bit patterns 0x3ff0000000000000
                // and 0x4000000000000000: both have low 32 bits == 0, so a
                // 4-byte-truncated comparison would wrongly collapse them
                // into a single entry, even though the high 32 bits (and so
                // the full 64-bit patterns) differ.
                double lo = key(1.0);
                double hi = key(2.0);
                int[double] table;
                table[lo] = 9;
                table[hi] = 11;

                assert((lo in table) !is null);
                assert((hi in table) !is null);
                assert(table[lo] == 9);
                assert(table[hi] == 11);
                assert(table.length == 2);
            }
        });
    }
}

// A `string` key compares the content its slice descriptor points at, not
// the descriptor's own bytes: two separately-materialised but content-equal
// strings are the same key.
static foreach (backend; Matrix!()) {
    @("assocArray.stringKeyComparesByContentNotIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[string] table;
                table["a"] = 42;

                assert(("a" in table) !is null);
                assert(table["a"] == 42);
                assert(table.length == 1);
            }
        });
    }
}

// `foreach (k, v; aa)` must read each key back at its own real width, not a
// hardcoded 4-byte `int` truncation of it.
static foreach (backend; Matrix!()) {
    @("assocArray.foreachLongKeyReadsFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long key(long value) {
                return value;
            }

            unittest {
                int[long] table;
                table[key(1L << 40)] = 7;
                table[key(1L << 41)] = 9;

                int count;
                foreach (k, v; table) {
                    assert(table[k] == v);
                    count += v;
                }
                assert(count == 16);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.foreachDoubleKeyReadsFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            double key(double value) {
                return value;
            }

            unittest {
                int[double] table;
                table[key(3.14159)] = 9;
                table[key(2.71828)] = 11;

                int count;
                foreach (k, v; table) {
                    assert(table[k] == v);
                    count += v;
                }
                assert(count == 20);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.foreachStringKeyReadsFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[string] table;
                table["a"] = 42;
                table["bb"] = 5;

                int count;
                int lengthSum;
                foreach (k, v; table) {
                    assert(table[k] == v);
                    count += v;
                    lengthSum += cast(int) k.length;
                }
                assert(count == 47);
                assert(lengthSum == 3);
            }
        });
    }
}

// A struct key with no string/dynamic-array member (`Point`, two `int`
// fields) is compared and stored as its own raw bytes, the same treatment
// `assocArrayValueWidth` already gives a struct-typed AA *value*. Covers
// construction from a literal (`counts[Point(1, 2)] = v`, the synthesized
// `__aakeyN` temporary DMD's index lowering hoists a non-trivial key
// expression into) and from a plain struct local (`counts[p] = v`), lookup
// through both `[]` and `in`, and `foreach (k, v; counts)` reading the key
// back at its own struct width.
static foreach (backend; Matrix!()) {
    @("assocArray.structKeyRawBytesConstructLookupAndIterate." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }

            unittest {
                int[Point] counts;
                counts[Point(1, 2)] = 10;

                Point p = Point(3, 4);
                counts[p] = 20;

                assert((Point(1, 2) in counts) !is null);
                assert(counts[Point(1, 2)] == 10);
                assert(counts[p] == 20);
                assert(counts.length == 2);

                int sum;
                foreach (k, v; counts)
                    sum += k.x + k.y + v;
                assert(sum == 1 + 2 + 10 + 3 + 4 + 20);
            }
        });
    }
}

// Struct AA keys compare dynamic-array members by their elements, not by the
// identity of their slice backing storage. Struct-typed key storage itself
// (`assocArrayKeyMeta`/`assocArrayKeyOffset`, raw-byte comparison, no string
// member) is now supported (`structKeyRawBytesConstructLookupAndIterate`
// above), so this row's refusal has moved past key compilation to
// `assert(Name(ab()) in ages)`'s synthesized boolean temporary
// (`__assertOpN = <InExp>`), a separate, so-far-unsupported assignment
// shape. Reaching that point does not mean the underlying gap (whole-struct
// raw-byte compare is wrong for a string member: two separately-constructed
// but content-equal strings have different backing pointers) is fixed --
// `keysEqual` still needs the same structural, not raw-byte, comparison it
// already gives a bare `string` key.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.refusal,
        "Unsupported assignment in bytecode core: __assertOp61 = "
            ~ "Name(ab()) in ages"),
)) {
    @("assocArray.structKeyWithStringMemberComparesStructurally." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Name {
                string text;
            }

            string ab() {
                return "ab";
            }

            unittest {
                int[Name] ages;
                ages[Name(ab())] = 1;
                assert((Name(ab()) in ages) !is null);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.nestedLookupDereferencesAssociativeArrayPointee." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[int][int] a = [1: [2: 3]];

                assert(a[1][2] == 3);
            }
        });
    }
}

// A dynamic-array-typed value (`int[][int]`): the value slot is a 16-byte
// slice descriptor, not an inline scalar. Interpreter reads back the wrong
// element (`0 != 20`) for this shape -- a separate, unconfirmed backend gap.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "int[][int] element reads back 0 instead of the inserted value"),
)) {
    @("assocArray.dynamicArrayValueInsertsReadsAndMutates." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[][int] a;
                a[1] = [10, 20, 30];

                assert(a.length == 1);
                assert(a[1].length == 3);
                assert(a[1][1] == 20);

                a[1][2] = 99;
                assert(a[1][2] == 99);

                int[] fetched = a[1];
                assert(fetched == [10, 20, 99]);
            }
        });
    }
}

// `int[][int].values` packs each entry at its own 16-byte slice-descriptor
// stride (`assocArrayValueWidth`), not a hardcoded 4-byte `int`. Reading
// values back at the wrong (scalar) stride would misalign every entry after
// the first -- summing every element of every entry is order-independent
// (AA iteration order is unspecified) but still catches a misaligned read.
static foreach (backend; Matrix!()) {
    @("assocArray.valuesOnArrayValuedAAReadsFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[] pair(int a, int b) {
                return [a, b];
            }

            unittest {
                int[][int] a;
                a[1] = pair(10, 20);
                a[2] = pair(30, 40);

                int[][] vs = a.values;
                assert(vs.length == 2);
                assert(vs[0].length == 2);
                assert(vs[1].length == 2);

                int total;
                foreach (entry; vs)
                    foreach (x; entry)
                        total += x;
                assert(total == 100);
            }
        });
    }
}

// A struct-typed value (`Point[int]`): the same `p[0]` `_d_aaGetRvalueX`
// rvalue-read shape as `dynamicArrayValueInsertsReadsAndMutates` above, but
// for a struct rather than a dynamic array. Interpreter refuses the field
// write -- a separate, unconfirmed backend gap.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "Unsupported interpreter assignment target"),
)) {
    @("assocArray.structValueFieldReadWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }
            unittest {
                Point[int] a;
                a[1] = Point(10, 20);
                assert(a[1].x == 10);
                a[1].x = 5;
                assert(a[1].x == 5);
                assert(a[1].y == 20);
            }
        });
    }
}

// A direct consequence of the fix above: calling a mutating method through
// an AA-value struct receiver (`a[1].bump()`) is the same
// `IndexExp`-over-pointer-to-`Tstruct` receiver shape as the plain field
// write above, but reached through `methodReceiver` rather than
// `tryStructField`. Interpreter segfaults on the same shape -- a separate,
// unconfirmed backend gap.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "segfaults calling a mutating method through an AA-value struct "
            ~ "receiver"),
)) {
    @("assocArray.structValueMethodCallMutatesEntry." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point {
                int x;
                int y;
                int bump() { return x += 1; }
            }
            unittest {
                Point[int] a;
                a[1] = Point(10, 20);
                a[1].bump();
                assert(a[1].x == 11);
                assert(a[1].y == 20);
            }
        });
    }
}

// A struct value with a user-defined `opAssign` (`Setting`, as opposed to
// the plain `Point` above): DMD represents `a[1] = Setting(2)` as a
// ConstructExp (blitting the fresh rvalue directly into the newly obtained
// AA slot -- `opAssign` is never invoked for this initial-insert shape) with
// an `IndexExp` `e1`, a lvalue shape `compileExpression`'s ConstructExp
// dispatch previously only recognised over a `DotVarExp`/`VarExp`/
// `SliceExp`/`ThisExp` lvalue, not an AA-element `IndexExp`.
static foreach (backend; Matrix!()) {
    @("assocArray.structValueWithOpAssignInsertsFromLiteral." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Setting {
                int value;

                void opAssign(Setting rhs) {
                    value = rhs.value;
                }
            }
            unittest {
                Setting[int] a;
                a[1] = Setting(2);
                assert(a[1].value == 2);
            }
        });
    }
}

// Overwriting an existing AA entry from another struct value (as opposed to
// the fresh-insert case above) lowers through the `_d_aaGetY` slot-pointer
// write shape (`p[i] = rhs`, `tryPointerElementAssign`/`storeThroughPointer`)
// regardless of whether the value type defines `opAssign` -- an AA element
// overwrite blits the value's raw bytes rather than dispatching through
// `opAssign`. `storeThroughPointer` previously only materialised the rhs
// through `compileExpression`, which handles a struct rvalue (a literal or
// constructor call) but not a struct lvalue (an existing local, reached the
// same way `structOperandOffset` resolves every other struct-value read).
static foreach (backend; Matrix!()) {
    @("assocArray.structValueOverwriteFromVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }
            unittest {
                Point pt;
                pt.x = 3;
                pt.y = 4;

                Point[int] a;
                a[1] = Point(10, 20);
                a[1] = pt;
                assert(a[1].x == 3);
                assert(a[1].y == 4);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.equalityComparesRuntimeEntries." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] left = [
                    first: first + 30,
                    second: second + 30,
                ];
                int[int] same = [
                    second: second + 30,
                    first: first + 30,
                ];
                int[int] different = [
                    first: first + 30,
                    second: second + 31,
                ];

                assert(left == same);
                assert(left != different);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.removeRuntimeKey." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int removeKey = key(10);
                int remainingKey = key(removeKey + 1);
                int[int] values = [
                    removeKey: removeKey + 30,
                    remainingKey: remainingKey + 30,
                ];

                assert(values.remove(removeKey) == true);
                assert(values.remove(removeKey) == false);
                assert(values.length == 1);
                assert(values[remainingKey] == 41);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.dupCopiesEntries." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int seed) {
                return seed;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] original = [
                    first: first + 30,
                    second: second + 30,
                ];
                int[int] copy = original.dup;

                original[first] = key(99);

                assert(copy.length == original.length);
                assert(copy[first] == 40);
                assert(copy[second] == 41);
                assert(original[first] != copy[first]);
            }
        });
    }
}

// Bytecode ("Unsupported bytecode assignment target.") and IR ("Unsupported
// IR expression `null`") cannot run AA insertion.
static foreach (backend; Matrix!()) {
    @("assocArray.insertionGrowsAndOverwrites." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int first = key(10);
                int second = key(first + 1);
                int[int] values;

                values[first] = first + 30;
                assert(values.length == 1);

                values[second] = second + 30;
                assert(values.length == 2);

                values[first] = first + 32;
                assert(values.length == 2);

                assert(values[first] == 42);
                assert(values[second] == 41);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.nullAACalleeInsertInvisible." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void insert(int[int] aa) {
                aa[1] = 2;
            }

            unittest {
                int[int] aa;
                insert(aa);
                assert(aa.length == 0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("assocArray.nullAAAssignmentInsertDetaches." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[int] aa;
                int[int] bb = aa;
                bb[1] = 2;
                assert(aa.length == 0);
                assert(bb.length == 1);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe, Interpreter)) {
    @("assocArray.readMissingKeyThrowsDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int present = key(10);
                int absent = key(present + 1);
                int[int] values = [present: present + 30];

                auto missing = values[absent];

                assert(missing == 0);
            }
        }).shouldThrowWithMessage(
            "key `absent` not found in associative array `values`",
        );
    }
}

// Compiled missing-key reads raise druntime's plain "Range violation"; the
// key/array-name text is CTFE-only.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
    Omit!(Interpreter, Because.diverges, "see sibling pin above (Ctfe, Interpreter)"),
)) {
    @("assocArray.readMissingKeyThrowsDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int key(int value) {
                return value;
            }

            unittest {
                int present = key(10);
                int absent = key(present + 1);
                int[int] values = [present: present + 30];

                auto missing = values[absent];

                assert(missing == 0);
            }
        }).shouldThrowWithMessage("Range violation");
    }
}



/++
    Pointer operations over dynamic arrays.
+/
static foreach (backend; Matrix!()) {
    @("pointer.arithmeticOverDynamicArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int offset(int value) {
                return value;
            }

            unittest {
                int first = offset(10);
                int[] values = [first, first + 1, first + 2, first + 3];
                int step = offset(2);
                int one = offset(1);
                int* p = &values[0];
                int* q = p + step;
                int* r = one + p;
                int* s = q - 1;

                assert(*q == 12);
                assert(*r == 11);
                assert(*s == 11);
                assert(q - p == 2);
                assert((p + 3) - r == 2);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("pointer.indexReadsDynamicArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                size_t index = cast(size_t) value(2);
                int* p = values.ptr;
                int found = p[index];

                assert(found == values[2]);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "pointer comparison expects a native pointer representation"),
)) {
    @("pointer.comparisonWithinArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                int* p = &values[0];
                int* middle = &values[1];
                int* q = &values[2];

                assert(p < q);
                assert(p <= p);
                assert(q > p);
                assert(q >= middle);
                assert(p == &values[0]);
                assert(q != p);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "cross-array pointer relations expect a native pointer representation"),
)) {
    @("pointer.relationsAcrossArraysReturnFalse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] left = [first, first + 1];
                int[] right = [first + 2, first + 3];
                size_t len = cast(size_t) value(1);
                int* lp = left.ptr;
                int* rp = right.ptr;

                bool insideSameRangeShape = lp >= rp && lp + len <= rp + len;

                int otherFirst = value(20);
                int[] otherLeft = [otherFirst, otherFirst + 1];
                int[] otherRight = [otherFirst + 2, otherFirst + 3];
                size_t offset = cast(size_t) value(1);
                int* leftStart = otherLeft.ptr;
                int* rightStart = otherRight.ptr;
                int* rightEnd = rightStart + offset;

                bool insideHalfOpenRange =
                    rightStart <= leftStart && leftStart < rightEnd;

                assert(insideSameRangeShape == false);
                assert(insideHalfOpenRange == false);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("pointer.sliceFromDynamicArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];
                int* p = &values[1];
                size_t start = 0;
                size_t stop = 2;

                auto slice = p[start .. stop];

                assert(slice.length == 2);
                assert(slice[1] == values[2]);
            }
        });
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("pointer.slicePastAllocatedBlockDiagnostic." ~ backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1];
                int* p = &values[0];
                size_t start = cast(size_t) seed(1);
                size_t stop = cast(size_t) seed(3);

                auto tail = p[start .. stop];

                assert(tail.length == 2);
            }
        }).shouldThrowWithMessage(
            "pointer slice `[1..3]` exceeds allocated memory block `[0..2]`",
        );
    }
}

// Compiled pointer slicing is unchecked: the allocated-block diagnostic is
// CTFE-only and the fixture just passes (the slice is never dereferenced).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin above (Ctfe)"),
    Omit!(Interpreter, Because.unconfirmed,
        "does not produce the allocated-block diagnostic"),
)) {
    @("pointer.slicePastAllocatedBlockDiagnostic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int first = seed(10);
                int[] values = [first, first + 1];
                int* p = &values[0];
                size_t start = cast(size_t) seed(1);
                size_t stop = cast(size_t) seed(3);

                auto tail = p[start .. stop];

                assert(tail.length == 2);
            }
        });
    }
}


// Bytecode ("Unsupported bytecode assignment target."), Bytecode
// ("Unsupported type in bytecode core: int[]"), and IR ("Unsupported IR
// expression `[first, first + 1, first + 2]`") cannot run this .dup fixture.
static foreach (backend; Matrix!()) {
    @("dynamicArray.dupDetachesCopyFromOriginal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];

                int[] copy = values.dup;
                copy[0] = value(99);

                assert(copy.length == 3);
                assert(copy[0] == 99);
                assert(values[0] == 10);
                assert(copy[1] == values[1]);
            }
        });
    }
}

// Bytecode ("Unsupported bytecode assignment target."), Bytecode
// ("Unsupported type in bytecode core: int[]"), and IR (unsupported array
// literal expression) cannot run this .idup fixture.
static foreach (backend; Matrix!()) {
    @("dynamicArray.idupFreezesIndependentCopy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1];

                immutable(int)[] frozen = values.idup;
                values[0] = value(99);

                assert(frozen[0] == 10);
                assert(frozen[1] == 11);
                assert(values[0] == 99);
            }
        });
    }
}

// `dupArrayOp`/`dupArrayElementSize` used to only distinguish 1-, 2-, or
// "other" (silently treated as 4-)-byte elements, so `.dup`/`.idup` mis-sized
// any 8-byte-or-wider element (`long`/`double`/pointer): the heap block was
// under-allocated and under-copied, corrupting the tail element(s).
static foreach (backend; Matrix!()) {
    @("dynamicArray.dupIdupPreserveEightByteElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long longValue(long seed) {
                return seed;
            }

            double doubleValue(double seed) {
                return seed;
            }

            unittest {
                long first = longValue(1_000_000_000_000L);
                long[] longs =
                    [first, first + 1, first + 2, first + 3];

                long[] longCopy = longs.dup;
                longCopy[0] = longValue(-1);

                assert(longCopy.length == 4);
                assert(longCopy[0] == -1);
                assert(longs[0] == 1_000_000_000_000L);
                assert(longCopy[1] == longs[1]);
                assert(longCopy[2] == longs[2]);
                assert(longCopy[3] == longs[3]);

                double firstDouble = doubleValue(1.5);
                double[] doubles = [firstDouble, firstDouble + 1.5];

                immutable(double)[] frozenDoubles = doubles.idup;
                doubles[0] = doubleValue(-2.5);

                assert(frozenDoubles[0] == 1.5);
                assert(frozenDoubles[1] == 3.0);
                assert(doubles[0] == -2.5);
            }
        });
    }
}

// Bytecode ("Unsupported cast target: Tpointer") and IR (unsupported array
// literal expression) cannot run this .ptr fixture.
static foreach (backend; Matrix!()) {
    @("dynamicArray.ptrPointsAtFirstElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[] values = [first, first + 1, first + 2];

                assert(values.ptr is &values[0]);
                assert(*values.ptr == 10);
                assert(values.ptr[2] == 12);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("pointer.indexAssignmentWritesArrayStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Buffer {
                char* data;

                this(char[] storage) {
                    data = storage.ptr;
                }

                void put(size_t index, char value) {
                    data[index] = value;
                }
            }

            unittest {
                char[2] storage;
                auto buffer = Buffer(storage[]);

                buffer.put(1, 'x');

                assert(storage[1] == 'x');
            }
        });
    }
}

// A whole-object assignment through a pointer to a static array
// (`int[3]*`) must write all of the pointee's bytes, not just the width of
// its own element type.
static foreach (backend; Matrix!()) {
    @("pointer.wholeStaticArrayAssignmentWritesRealStorage." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[3] arr = [1, 2, 3];
                int[3]* p = &arr;
                *p = [4, 5, 6];

                assert(arr[0] == 4);
                assert(arr[1] == 5);
                assert(arr[2] == 6);
            }
        });
    }
}

// A `ref` parameter bound to a static array reached by dereferencing a
// pointer to it (`bump(*p)` where `p: int[3]*`) must mirror and write back
// the whole array, the same width question as the whole-object assignment
// above but through the ref-argument mirror/writeback path instead.
static foreach (backend; Matrix!()) {
    @("pointer.refArgumentThroughStaticArrayDereferenceWritesRealStorage." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void bump(ref int[3] a) {
                a[0] = 99;
            }

            unittest {
                int[3] arr = [1, 2, 3];
                int[3]* p = &arr;
                bump(*p);

                assert(arr[0] == 99);
            }
        });
    }
}

// A slice assignment through a D pointer must write the pointed-at array
// storage, not sever the aliasing. This is the silently lost write distilled
// from cerealed.
enum pointerSliceAssignSource = q{
    unittest {
        char[8] tmp;
        auto p = tmp.ptr;

        p[2 .. 5] = "abc";

        assert(tmp[3] == 'b');
    }
};

static foreach (backend; Matrix!()) {
    @("pointer.sliceAssignmentWritesArrayStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(pointerSliceAssignSource);
    }
}

enum pointerSliceArgumentEvaluatesPointerOnceSource = q{
    unittest {
        char[2] first = ['a', 'b'];
        char[2] second = ['c', 'd'];
        int calls;

        char* getPointer() {
            ++calls;
            return calls == 1 ? first.ptr : second.ptr;
        }

        char readFirst(char[] slice) {
            return slice[0];
        }

        char value = readFirst(getPointer()[0 .. 1]);

        assert(calls == 1);
        assert(value == 'a');
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(LLVMJit, Because.unconfirmed),
)) {
    @("pointer.sliceArgumentEvaluatesPointerOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(
            pointerSliceArgumentEvaluatesPointerOnceSource,
        );
    }
}

// An indexed write through a local pointer into a `= void` static array is a
// sibling of the pointer-slice defect distilled from cerealed.
enum pointerIndexAssignVoidInitSource = q{
    unittest {
        char[8] tmp = void;
        auto p = tmp.ptr;

        p[0] = 'x';

        assert(tmp[0] == 'x');
    }
};

static foreach (backend; Matrix!()) {
    @("pointer.indexAssignmentWritesVoidInitialisedArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(pointerIndexAssignVoidInitSource);
    }
}

// cerealed's `static_array.d(7)` test decodes into a void-initialised static
// array (`Decerealiser.value!(int[2])`'s `T val = void;` overload, taken
// because `int[2]()` does not compile) and writes each element via
// `foreach (ref e; val) cereal.grain(e);` (cereal.d's static-array `grain`).
// dmd's foreach-to-for lowering slices a static array (`T[] __r = val[];`)
// even when `val` is already a plain local, so a write through `__r`'s
// per-element alias reaches `Walker.writeThroughSliceAlias` (impl.d), which
// read the alias source's `locals` entry as-is. A `ref` parameter bound to
// the caller's `= void` local carries the bare `Value.void_` placeholder
// there (the interpreter's deferred-read seeding for `ref` parameters), not
// a real `Array`,
// so rebuilding it via `withArrayElement` threw "Expected array." instead of
// writing the first element. `Bytecode` omitted: still under active
// development, does not yet write through this `ref` foreach loop variable
// (every element reads back as `0`).
enum staticArrayForeachRefVoidInitSource = q{
    void fillPair(ref int[2] val, int first) {
        int i;
        foreach (ref e; val) {
            e = first + i;
            ++i;
        }
    }

    int[2] decode(int first) {
        int[2] result = void;
        fillPair(result, first);
        return result;
    }

    unittest {
        int seed = 34;
        auto result = decode(seed);
        assert(result[0] == 34);
        assert(result[1] == 35);
    }
};

static foreach (backend; Matrix!()) {
    @("staticArray.foreachRefWritesVoidInitialisedElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(staticArrayForeachRefVoidInitSource);
    }
}

// A zero-length slice assignment through a null pointer is a no-op in
// compiled D: nothing is written, so the null provenance never matters.
// ScopeBuffer's own unittest hits this by
// `put`ting an empty slice into a default-initialised buffer.
enum pointerEmptyNullSliceAssignSource = q{
    struct Buffer {
        char* buf;
        uint used;

        void put(const(char)[] s) {
            const newlen = used + s.length;
            buf[used .. newlen] = s[];
            used = cast(uint) newlen;
        }
    }

    unittest {
        Buffer b;
        string empty;

        b.put(empty);

        assert(b.used == 0);
    }
};

static foreach (backend; Matrix!()) {
    @("pointer.emptySliceAssignmentThroughNullPointerIsNoOp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(pointerEmptyNullSliceAssignSource);
    }
}

// Bytecode ("Unsupported expression `rows.length`"), Bytecode
// ("Unsupported type in bytecode core: int[][]"), and IR (unsupported nested
// array literal) cannot run jagged arrays.
static foreach (backend; Matrix!()) {
    @("dynamicArray.jaggedRowsKeepIndependentLengths." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(10);
                int[][] rows = [[first, first + 1, first + 2], [first + 3]];

                assert(rows.length == 2);
                assert(rows[0].length == 3);
                assert(rows[1].length == 1);
                assert(rows[0][2] == 12);
                assert(rows[1][0] == 13);

                rows[1] ~= first + 4;
                assert(rows[1].length == 2);
                assert(rows[1][1] == 14);
                assert(rows[0].length == 3);
            }
        });
    }
}

// Owed §9.10 gap fixture (ai/plans/interpreter.md): the oracle's real
// `reserve` contract. Ctfe omitted:
// pointer-identity `is` on a GC-backed slice lowers to an address cast CTFE
// refuses at compile time.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "pointer-identity `is` on a GC-backed slice lowers to an address cast CTFE refuses at compile time"),
    Omit!(Interpreter, Because.unconfirmed,
        "reserve loses the zero-length allocation's pointer identity"),
)) {
    @("dynamicArray.reserveThenAppendWithinCapacityDoesNotReallocate." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] arr;
                const reserved = arr.reserve(8);
                assert(reserved >= 8);

                auto ptr = arr.ptr;
                foreach (i; 0 .. 8)
                    arr ~= i;

                assert(arr.ptr is ptr);
            }
        });
    }
}

// This fixture pins `assumeSafeAppend` through an interior pointer (a slice
// that does not start at its backing block's base). Interpreter omitted: its
// reserve descriptor loses the zero-length allocation's capacity when the
// descriptor is rebound into the caller. Ctfe omitted:
// `gc_getArrayUsed` has no D source, so Ctfe cannot intercept it at all.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "gc_getArrayUsed has no D source, so Ctfe cannot intercept it at all"),
    Omit!(Interpreter, Because.unconfirmed,
        "reserve capacity is not retained when the zero-length slice descriptor is rebound"),
)) {
    @("dynamicArray.assumeSafeAppendOnInteriorSliceAppendsInPlace." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[] arr;
                arr.reserve(8);
                arr ~= 1;
                arr ~= 2;
                arr ~= 3;
                arr ~= 4;

                auto tail = arr[2 .. $];
                tail.assumeSafeAppend();
                auto tailPtr = tail.ptr;
                tail ~= 99;

                assert(tail.ptr is tailPtr);
                assert(tail[2] == 99);
            }
        });
    }
}

// cerealed's decode loop grows an array one element at a time and reads the
// element it just appended via `$` (`val.length++; cereal.grain(val[$ - 1])`,
// cereal.d's grainRawArray/grainWithLengthInBytesAttr): `$` must reflect the
// array's length as of *this* index expression, computed after the growth
// that precedes it, not a stale value from before the growth ran -- reading
// it before the update underflows `size_t` instead of yielding the true
// index. The write inside `grown` deliberately indexes via
// `arr.length - 1`, not `$`, so this fixture isolates the read-side `$`
// defect the fix targets.
static foreach (backend; Matrix!()) {
    @("dynamicArray.dollarReflectsLengthAfterInPlaceGrowth." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[] grown(int count) {
                int[] arr;
                foreach (i; 0 .. count) {
                    arr.length++;
                    arr[arr.length - 1] = i + 1;
                }
                return arr;
            }

            unittest {
                assert(grown(3)[$ - 1] == 3);
            }
        });
    }
}

// cerealed's `grainWithLengthInBytesAttr` shape:
// `cereal.grain(val.arr[$ - 1])`, where `grain` takes a `ref T` parameter,
// so the callee's write must land back in the caller's array element --
// this fixture pins that ref-argument array-element write-back.
static foreach (backend; Matrix!()) {
    @("dynamicArray.refParamWriteBackThroughIndexArgument." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            void setTo(ref int x, int v) {
                x = v;
            }

            unittest {
                int[] arr;
                arr.length = 3;
                setTo(arr[1], 7);
                assert(arr[1] == 7);
            }
        });
    }
}

// The same ref-argument array-element write-back as above, for an element
// wider than a register (a 24-byte struct) rather than a scalar: the
// writeback must use the element's own real width instead of refusing the
// call or corrupting a neighbouring element.
static foreach (backend; Matrix!()) {
    @("dynamicArray.refParamWriteBackThroughIndexArgumentWithStructElementWiderThan16Bytes."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
                long c;
            }

            void bump(ref S s) {
                s.a += 100;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                S[] arr;
                arr ~= S(seed(1), seed(2), seed(3));
                arr ~= S(seed(4), seed(5), seed(6));

                bump(arr[1]);

                assert(arr[1].a == 104);
                assert(arr[1].b == 5);
                assert(arr[1].c == 6);
                assert(arr[0].a == 1);
            }
        });
    }
}

// The ref-returning-wrapper counterpart of the test above: `first` is a
// `ref`-returning function whose final statement returns one element of its
// by-value array parameter, and the outer call binds that element to
// another function's `ref` parameter. The element is a 24-byte struct, wider
// than a register, so the writeback must use the element's own real width
// instead of refusing the call.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.diverges,
        "confirmed via bin/qb: ref argument bound to a ref-returning " ~
        "wrapper's returned array element loses the writeback regardless " ~
        "of element width"),
)) {
    @("dynamicArray.refReturningWrapperWriteBackThroughIndexArgumentWithStructElementWiderThan16Bytes."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct S {
                long a;
                long b;
                long c;
            }

            ref S first(S[] arr) {
                return arr[0];
            }

            void bump(ref S s) {
                s.a += 100;
            }

            int seed(int value) {
                return value;
            }

            unittest {
                S[] arr;
                arr ~= S(seed(1), seed(2), seed(3));
                arr ~= S(seed(4), seed(5), seed(6));

                bump(first(arr));

                assert(arr[0].a == 101);
                assert(arr[0].b == 2);
                assert(arr[0].c == 3);
                assert(arr[1].a == 4);
            }
        });
    }
}

// A nested `foreach` re-declares the
// inner loop's slice temporary (dmd lowers `foreach (v; row)` to a fresh
// `auto __r = row[];` every OUTER iteration) over the SAME `VarDeclaration`
// at every outer pass. `promoteSliceArrayCell` promotes `row` itself
// (the slice source) eagerly as a side effect -- no address-of needed --
// and, without dropping that stale cell on `row`'s own fresh re-declaration
// each outer iteration, the second outer iteration's inner loop reads back
// the FIRST iteration's stale cell bytes instead of its own row's values.
// SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
    @("dynamicArray.nestedForeachDropsStaleArrayCellOnFreshRowBinding." ~
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

            int f() {
                int sum;
                foreach (row; [[one(), two()], [three()]])
                    foreach (v; row)
                        sum += v;
                return sum;
            }

            unittest {
                assert(f() == 6);
            }
        });
    }
}

// `writeCelledLocal`'s `arrayCells`
// branch treated ANY same-length whole-array assignment as an in-place byte
// mutation -- correct for the ref-writeback case it was built for, but a
// plain source-level `s = b;` REBINDS `s` to `b`'s storage; it must not
// write `b`'s bytes into whatever `s` used to alias. Here `s` is a slice
// view over `a`'s cell, so the buggy in-place refresh corrupted `a` itself.
// SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
    @("dynamicArray.wholeArrayRebindDoesNotWriteThroughStaleSliceCell." ~
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

            int eight() {
                return 8;
            }

            int nine() {
                return 9;
            }

            int f() {
                int[] a = [one(), two()];
                int[] s = a[];
                int[] b = [eight(), nine()];
                s = b;
                return a[0];
            }

            unittest {
                assert(f() == 1);
            }
        });
    }
}

// `a ~= x` (`runArrayAppendAssignExpression`'s
// plain-`VarExp` arm) grew `locals` but left a promoted `arrayCells` entry at
// its OLD length -- a slice (`int[] s = a[];`) eagerly promotes `a`'s cell via
// `promoteSliceArrayCell`, with no address-of needed at all. A later read of
// the newly-appended element then goes through `readIndexExpression`'s cell
// arm against the stale, too-short cell. SystemLinker is the oracle.
static foreach (backend; Matrix!()) {
    @("dynamicArray.appendRefreshesSlicePromotedStaleCell." ~
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
                int[] a = [one()];
                int[] s = a[];
                a ~= two();
                return a[1];
            }

            unittest {
                assert(f() == 2);
            }
        });
    }
}

// `runSliceAssignExpression` (`a[] = x` /
// `a[i .. j] = x`) writes `locals[variable]` directly but never refreshes a
// promoted `arrayCells` entry, which `readIndexExpression`'s cell arm reads
// in preference to the boxed mirror. Here `s = a[]` promotes `a`'s cell
// eagerly (no address-of), so `a[] = ninetyNine()` fills the boxed array but
// a later `a[0]` read returns the stale cell's original value instead. See
// the sibling `pointer.boundedSliceAssignmentWritesThroughAddressOfPromotedCell`
// fixture in expressions.d for the bounded/`&a[0]` variant. SystemLinker is
// the oracle.
static foreach (backend; Matrix!()) {
    @("dynamicArray.sliceFillAssignmentWritesThroughSlicePromotedCell." ~
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
                int[] a = [one(), two()];
                int[] s = a[];
                a[] = ninetyNine();
                return a[0];
            }

            unittest {
                assert(f() == 99);
            }
        });
    }
}

// `runSliceAssignExpression`'s
// cell-refresh loop indexed `lower .. upper` unconditionally against
// `elements` (built with only `current.length` entries), so an out-of-bounds
// guest `a[0 .. 5] = x` on a 2-element array indexed `elements` past its own
// bounds and died with a HOST `core.exception.RangeError` -- even when
// `variable` never had a promoted cell at all, since `elements[index]` is
// built as the call argument before `writeThroughArrayCell`'s own no-op
// check ever runs. Fix: reject an out-of-bounds `upper` up front, before
// `elements` is built (or `rhs` is even evaluated), with the interpreter's
// own guest-visible `RangeError`, using the exact wording compiled D's own
// `ArraySliceError` raises for the identical slice assignment (confirmed
// against a real `dmd`-compiled `int[] a = [1, 2]; a[0 .. 5] = 9;`).
// SystemLinker is the oracle; other backends omitted per the omit-don't-pin
// convention (unconfirmed there).
// Ctfe omitted (unconfirmed, no sibling pin yet): DMD's CTFE engine is
// expected to reject the out-of-bounds slice assignment with its own
// compile-time diagnostic wording ("slice `[0..5]` exceeds array bounds
// `[0..2]`") rather than the runtime `RangeError` message this fixture pins,
// but that has not been characterized with a dedicated test.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "DMD's CTFE engine reports its own compile-time diagnostic wording here, but no sibling pin test captures it"),
)) {
    @("dynamicArray.sliceAssignPastLengthThrowsRangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(1);
                int[] a = [first, first + 1];
                size_t lower = cast(size_t) value(0);
                size_t upper = cast(size_t) value(5);

                a[lower .. upper] = value(9);
            }
        }).shouldThrowWithMessage(
            "slice [0 .. 5] extends past source array of length 2",
        );
    }
}


/++
    Truthiness of dynamic arrays and slices.
+/
// A dynamic array's truthiness follows `ptr !is null`, read at the pointer's
// full width -- not a low-byte read of the length word, which happened to
// read a 256-length array's zero low byte as false.
static foreach (backend; Matrix!()) {
    @("dynamicArray.truthinessIsPointerNotNullAtFullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                size_t len = cast(size_t) seed(256);
                int[] a = new int[len];
                assert(a ? true : false);

                int[] n;
                assert(!(n ? true : false));
            }
        });
    }
}

// A non-null zero-length slice (its pointer is set but length is 0) is still
// truthy: truthiness follows the pointer, not the length.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "observed via bin/qb: `assert(s ? true : false)` for a non-null " ~
        "zero-length slice evaluates false on Interpreter; SystemLinker " ~
        "evaluates true"),
)) {
    @("dynamicArray.nonNullZeroLengthSliceIsTruthy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                size_t len = cast(size_t) seed(256);
                int[] a = new int[len];
                size_t start = cast(size_t) seed(2);
                auto s = a[start .. start];

                assert(s ? true : false);
            }
        });
    }
}


/++
    Static arrays of strings and of dynamic arrays.
+/
static foreach (backend; Matrix!()) {
    @("staticArray.foreachOverStringElementsReadsElementContent." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                string[2] a = ["x", "yz"];
                int total;

                foreach (s; a) total += cast(int) s.length;

                assert(total == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.foreachOverWholeSliceOfStringArrayReadsElementContent." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                string[2] a = ["x", "yz"];
                string[] s = a[];
                int total;

                foreach (e; s) total += cast(int) e.length;

                assert(s.length == 2);
                assert(total == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.foreachOverArrayOfArraysReadsRowLengths." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(1);
                int[][2] a = [[first, first + 1], [first + 2]];
                int n;

                foreach (row; a) n += cast(int) row.length;

                assert(n == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.partialSliceOfArrayOfArraysReadsElementContent." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int value(int seed) {
                return seed;
            }

            unittest {
                int first = value(1);
                int[][3] b = [
                    [first],
                    [first + 1, first + 2],
                    [first + 3, first + 4, first + 5],
                ];

                auto s = b[1 .. 3];

                assert(s[0][1] == first + 2);
                assert(s[1][2] == first + 5);
            }
        });
    }
}


/++
    `cast(void*)` of a string reads its raw byte storage through `.ptr`,
    same as a dynamic array.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.stringPointerReadsUtf8SecondByte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            string text() {
                return "aβ";
            }

            unittest {
                string s = text();

                assert(s.ptr[1] == 0xCE);
            }
        });
    }
}


/++
    `s[i]` for a `string` local reads the code unit directly (without going
    through `.ptr` first), matching the compiled-D oracle.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.stringIndexReadsElementAtRuntimeIndex." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                string s = "hello";
                int index = seed(1);

                assert(s[index] == 'e');
                assert(s[0] == 'h');
            }
        });
    }
}


/++
    `.ptr` of a `string` sub-slice (`a[lo .. hi]`) reads the sliced region, not
    a wild address: the sub-slice descriptor must resolve to a real pointer
    into the original string's backing data, offset by `lo`.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.stringSubSlicePointerReadsSlicedByte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                string a = "abcdef";
                string b = a[seed(1) .. seed(3)];
                immutable(char)* p = b.ptr;

                assert(b.length == 2);
                assert(p[0] == 'b');
                assert(b[0] == 'b');
            }
        });
    }
}


// An inverted sub-slice (`a[lo .. hi]` with `lo > hi`) must throw before a
// length is formed: computing `hi - lo` as an unsigned length silently wraps
// to a huge value instead of raising the bounds error compiled D raises.
// `Ctfe` and `Interpreter` are pinned separately below with their own
// divergent wording (confirmed via `bin/qb`, not guessed).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "Ctfe's own compile-time bounds check reports " ~
        "\"slice `[4..2]` exceeds array bounds `[0..6]`\"; see sibling pin below"),
    Omit!(Interpreter, Because.diverges,
        "Interpreter's sub-slice construction path raises druntime's plain " ~
        "\"Range violation\"; see sibling pin below"),
)) {
    @("dynamicArray.stringSubSliceWithInvertedRuntimeBoundsThrows." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                string a = "abcdef";
                string b = a[seed(4) .. seed(2)];
            }
        }).shouldThrowWithMessage(
            "slice [4 .. 2] has a larger lower index than upper index",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("dynamicArray.stringSubSliceWithInvertedRuntimeBoundsThrows." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                string a = "abcdef";
                string b = a[seed(4) .. seed(2)];
            }
        }).shouldThrowWithMessage(
            "slice `[4..2]` exceeds array bounds `[0..6]`",
        );
    }
}

static foreach (backend; AliasSeq!(Interpreter)) {
    @("dynamicArray.stringSubSliceWithInvertedRuntimeBoundsThrows." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                string a = "abcdef";
                string b = a[seed(4) .. seed(2)];
            }
        }).shouldThrowWithMessage("Range violation");
    }
}

// Same inverted-bounds invariant as the `string` sub-slice test above, but
// through `subSlice4` (4-byte `int` elements) rather than `subSlice1` (1-byte
// `char` elements) — both share the same generic `validateSubSlice`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "Ctfe's own compile-time bounds check reports " ~
        "\"slice `[4..2]` exceeds array bounds `[0..6]`\"; see sibling pin below"),
    Omit!(Interpreter, Because.diverges,
        "Interpreter's sub-slice construction path raises druntime's plain " ~
        "\"Range violation\"; see sibling pin below"),
)) {
    @("dynamicArray.subSliceWithInvertedRuntimeBoundsThrows." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[] a = [1, 2, 3, 4, 5, 6];
                int[] b = a[seed(4) .. seed(2)];
            }
        }).shouldThrowWithMessage(
            "slice [4 .. 2] has a larger lower index than upper index",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("dynamicArray.subSliceWithInvertedRuntimeBoundsThrows." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[] a = [1, 2, 3, 4, 5, 6];
                int[] b = a[seed(4) .. seed(2)];
            }
        }).shouldThrowWithMessage(
            "slice `[4..2]` exceeds array bounds `[0..6]`",
        );
    }
}

static foreach (backend; AliasSeq!(Interpreter)) {
    @("dynamicArray.subSliceWithInvertedRuntimeBoundsThrows." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int seed(int value) {
                return value;
            }

            unittest {
                int[] a = [1, 2, 3, 4, 5, 6];
                int[] b = a[seed(4) .. seed(2)];
            }
        }).shouldThrowWithMessage("Range violation");
    }
}


/++
    Plain reassignment of an already-declared `string` local from another
    `string` local (`b = a;`) must copy the full slice descriptor. A `string`
    local's slot holds the same native 16-byte {ptr, length} descriptor as any
    other dynamic array, which the scalar type mapping reports as size 0, so a
    naive scalar-sized copy would silently write nothing and leave `b`
    unchanged.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.stringLocalReassignmentFromVariableCopiesDescriptor." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            string greeting() {
                return "hello";
            }

            unittest {
                string a = greeting();
                string b = "x";
                b = a;

                assert(b.length == 5);
                assert(b[0] == 'h');
            }
        });
    }
}


/++
    Plain reassignment of an already-declared `string` local from a string
    literal (`b = "hello";`) exercises the same reassignment path with a
    literal right-hand side rather than a variable read.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.stringLocalReassignmentFromLiteralCopiesDescriptor." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            string placeholder(string value) {
                return value;
            }

            unittest {
                string b = placeholder("x");
                b = "hello";

                assert(b.length == 5);
                assert(b[0] == 'h');
            }
        });
    }
}


/++
    Plain reassignment of an already-declared `string` local from a sub-slice
    of another `string` local (`b = a[lo .. hi];`) exercises the same
    reassignment path with a native {ptr, length}-descriptor sub-slice
    right-hand side.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.stringLocalReassignmentFromSubSliceCopiesDescriptor." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            string source() {
                return "abcdef";
            }

            unittest {
                string a = source();
                string b = "x";
                int lo = 1;
                int hi = 3;
                b = a[lo .. hi];

                assert(b.length == 2);
                assert(b[0] == 'b');
            }
        });
    }
}

/++
    A sub-slice of a heap-backed `string` (produced by `.idup`, not a
    data-segment literal) reads the sliced bytes and length by resolving the
    source's native {ptr, length} descriptor to its real heap block, not the
    program's read-only data segment.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.heapBackedStringSubSliceReadsSlicedBytesAndLength." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            char letter(int index) {
                return cast(char) ('a' + index);
            }

            int seed(int value) {
                return value;
            }

            unittest {
                char[] source = [
                    letter(0), letter(1), letter(2),
                    letter(3), letter(4), letter(5),
                ];
                string a = source.idup;
                string b = a[seed(1) .. seed(3)];

                assert(b.length == 2);
                assert(b[0] == 'b');
                assert(b[1] == 'c');
            }
        });
    }
}

/++
    Reassigning an already-declared `string` local (`b = "x";`) from a
    heap-backed `string` source (`.idup`) must copy the full 16-byte
    {ptr, length} descriptor; a partial copy would silently drop bytes of the
    pointer or the length.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.stringLocalReassignmentFromHeapBackedSourceCopiesDescriptor." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            char letter(int index) {
                return cast(char) ('a' + index);
            }

            unittest {
                char[] source = [
                    letter(0), letter(1), letter(2),
                    letter(3), letter(4), letter(5),
                ];
                string a = source.idup;
                string b = "x";
                b = a;

                assert(b.length == 6);
                assert(b[0] == 'a');
                assert(b[5] == 'f');
            }
        });
    }
}

/++
    Reassigning a `string` local from a heap-backed source inside an untaken
    `if` branch must not touch `b`: the branch never runs.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.stringLocalReassignmentFromHeapBackedSourceInConditionalLeavesUntakenBranchUnchanged." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            char letter(int index) {
                return cast(char) ('a' + index);
            }

            bool never() {
                return false;
            }

            unittest {
                char[] source = [letter(0), letter(1)];
                string a = source.idup;
                string b = "x";
                if (never())
                    b = a;

                assert(b.length == 1);
                assert(b[0] == 'x');
            }
        });
    }
}

/++
    Reassigning a `string` local from a heap-backed source inside a loop body
    must observe each iteration's own reassignment, not the value the local
    held before the loop started.
+/
static foreach (backend; Matrix!()) {
    @("dynamicArray.stringLocalReassignmentFromHeapBackedSourceInLoopUpdatesEachIteration." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            char letter(int index) {
                return cast(char) ('a' + index);
            }

            unittest {
                char[] source = [letter(0), letter(1)];
                string a = source.idup;
                string b = "x";
                ulong firstLength = 99;
                ulong secondLength = 99;

                foreach (i; 0 .. 2) {
                    if (i == 0)
                        firstLength = b.length;
                    else
                        secondLength = b.length;
                    b = a;
                }

                assert(firstLength == 1);
                assert(secondLength == 2);
            }
        });
    }
}

/++
    A string literal materialised early must stay intact after compiling a
    separate, not-yet-compiled function whose own (large) string literal
    grows literal storage: an earlier literal's descriptor must not dangle
    once later literal storage is (re)allocated.
+/
static foreach (backend; Matrix!()) {
    @("stringLiteralSurvivesLazyDataSegmentGrowth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import std.array: replicate;
        import std.conv: text;

        // Large enough that the not-yet-compiled `grow`'s own literal forces
        // a reallocation (not just an in-place growth) of literal storage.
        const growLiteral = "z".replicate(4096);
        runBackendSourceFixtureTests!backend(text(`
            string grow() {
                return "`, growLiteral, `";
            }

            unittest {
                string early = "early";
                const grown = grow();
                assert(early == "early");
                assert(grown.length == `, growLiteral.length, `);
            }
        `));
    }
}

// `sliceEqualOp` keys its comparison width on the element size, not always 4
// bytes: two `short` elements differing only in their high byte must compare
// unequal, not be over-read as identical 4-byte values.
static foreach (backend; Matrix!()) {
    @("dynamicArray.shortEqualityComparesFullElementWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            short[] build(short first, short second) {
                return [first, second];
            }

            unittest {
                short[] a = build(cast(short) 0x0102, cast(short) 3);
                short[] b = build(cast(short) 0x0202, cast(short) 3);
                short[] same = build(cast(short) 0x0102, cast(short) 3);

                assert(a != b);
                assert(a == same);
            }
        });
    }
}

// The same over-read risk applies at 8 bytes: two `long` elements differing
// only in their high 4 bytes must compare unequal, not be truncated to a
// 4-byte comparison.
static foreach (backend; Matrix!()) {
    @("dynamicArray.longEqualityComparesFullElementWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            long[] build(long first, long second) {
                return [first, second];
            }

            unittest {
                long[] a = build(0x1_0000_0000L, 2L);
                long[] b = build(2L, 2L);
                long[] same = build(0x1_0000_0000L, 2L);

                assert(a != b);
                assert(a == same);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.wstringEqualityComparesFullElementWidth." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            wstring greeting(int n) {
                return n == 1 ? "ab"w : "ac"w;
            }

            unittest {
                wstring a = greeting(1);
                wstring b = greeting(1);
                wstring c = greeting(2);

                assert(a == b);
                assert(a != c);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dynamicArray.dstringEqualityComparesFullElementWidth." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            dstring greeting(int n) {
                return n == 1 ? "ab"d : "ac"d;
            }

            unittest {
                dstring a = greeting(1);
                dstring b = greeting(1);
                dstring c = greeting(2);

                assert(a == b);
                assert(a != c);
            }
        });
    }
}

// Calling a mutating method through a receiver that is an element of a
// dynamic array of structs (`arr[0].bump()`, `Plain[] arr`): `methodReceiver`
// had no case for a `DotVarExp` callee receiver whose own base is a dynamic
// array index, so it fell through to the generic
// `structOperandOffset` -> `structBaseOffsetOrMaterialise` path, which
// materialises the element via `loadDynamicArrayElement`'s plain
// `indexLoadOp` copy into a throwaway frame block with no write-back
// registered -- the mutation was silently dropped. `methodReceiver` now
// resolves this shape the same way `emitDynamicArrayElementRefArgument`
// already does for the identical shape reached as a `ref` argument, and
// writes the (possibly mutated) copy back through `indexStoreOp` afterward.
// Two `bump()` calls before the read check the writeback actually lands (a
// no-writeback bug would silently discard both mutations rather than crash).
static foreach (backend; Matrix!()) {
    @("dynamicArray.methodCallThroughElementReceiverMutatesElement." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Plain {
                int x;
                int get() const { return x; }
                void bump() { x++; }
            }

            unittest {
                Plain[] arr = [Plain(1), Plain(2)];
                arr[0].bump();
                arr[0].bump();
                assert(arr[0].get() == 3);
                assert(arr[1].get() == 2);
            }
        });
    }
}

// The dynamic-array-element counterpart of
// `assocArray.structValueOverwriteFromVariable` above:
// `tryDynamicArrayElementAssign`'s main branch only materialised its rhs
// through `compileExpression`, which handles a struct rvalue (a literal or
// constructor call) but not a struct lvalue (an existing local, reached the
// same way `structOperandOffset` resolves every other struct-value read).
static foreach (backend; Matrix!()) {
    @("dynamicArray.structElementOverwriteFromVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }
            unittest {
                Point[] arr = [Point(1, 2)];
                Point p = Point(9, 9);
                arr[0] = p;
                assert(arr[0].x == 9);
                assert(arr[0].y == 9);
            }
        });
    }
}

// The static-array-element counterpart, resolved to a compile-time-constant
// inline frame offset rather than a runtime descriptor:
// `compileStaticArrayElementAssign` had the identical
// compileExpression-only-handles-a-struct-rvalue gap.
static foreach (backend; Matrix!()) {
    @("staticArray.structElementOverwriteFromVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Point { int x; int y; }
            unittest {
                Point[2] arr = [Point(1, 2), Point(3, 4)];
                Point p = Point(9, 9);
                arr[1] = p;
                assert(arr[1].x == 9);
                assert(arr[1].y == 9);
            }
        });
    }
}

// `arr[i].structField = rhs` for a dynamic array of structs, where the
// written field is itself struct-typed and the rhs is an rvalue (a
// constructor call): the resolved element-field pointer's write side,
// `storeArrayElementFieldPointer`, special-cased a `Tarray` field but fell
// through to a generic scalar path for everything else, which threw
// resolving a struct field's scalar type. It now routes a `Tstruct` field
// through `structOperandOffset`, the same way `storeThroughPointer` already
// does for a struct-typed pointer write.
static foreach (backend; Matrix!()) {
    @("dynamicArray.structFieldOfStructElementWrittenFromConstructorCall." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner { int v; }
            struct Outer { Inner inner; int tag; }
            unittest {
                Outer[] arr = [Outer(Inner(1), 10)];
                arr[0].inner = Inner(55);
                assert(arr[0].inner.v == 55);
                assert(arr[0].tag == 10);
            }
        });
    }
}

// The same shape, but the rhs is an existing struct lvalue rather than a
// constructor-call rvalue: `compileExpression` alone cannot materialise an
// existing struct variable, the same gap `storeThroughPointer` already
// works around via `structOperandOffset`.
static foreach (backend; Matrix!()) {
    @("dynamicArray.structFieldOfStructElementWrittenFromVariable." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner { int v; }
            struct Outer { Inner inner; int tag; }
            unittest {
                Outer[] arr = [Outer(Inner(1), 10)];
                Inner existing = Inner(77);
                arr[0].inner = existing;
                assert(arr[0].inner.v == 77);
            }
        });
    }
}

// The class-array-field sibling of the case above (`c.arr[i].field = rhs`):
// `storeArrayElementFieldPointer` also serves
// `tryClassArrayFieldElementFieldPointer`'s resolved pointer, so the same
// `Tstruct` branch closes this shape too. `Interpreter` throws "Expected
// class object." on this receiver shape even for a plain scalar field
// (confirmed via bin/ut with `c.arr[0].tag = 99;`), a pre-existing gap
// unrelated to the struct-field fix here.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "class array-of-structs element field write throws " ~
        "\"Expected class object.\" even for a scalar field"),
)) {
    @("classField.structFieldOfArrayOfStructsElementWrittenFromConstructorCall." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Inner { int v; }
            struct Item { Inner inner; int tag; }
            class C { Item[] arr; }
            unittest {
                auto c = new C();
                c.arr = [Item(Inner(1), 10)];
                c.arr[0].inner = Inner(55);
                assert(c.arr[0].inner.v == 55);
                assert(c.arr[0].tag == 10);
            }
        });
    }
}

// The `Tsarray` sibling of the struct-field case above: `arr[i].fixedField =
// [x, y, z]` for a dynamic-array-of-structs element whose field is itself a
// static array. `storeArrayElementFieldPointer` had no `Tsarray` branch at
// all and threw "Unsupported type in bytecode core: int[3]"; it now routes
// the field through `compileStaticArrayValueInto`, the same whole-value
// helper a static-array local's own declaration/assignment uses.
static foreach (backend; Matrix!()) {
    @("dynamicArray.staticArrayFieldOfStructElementWrittenFromLiteral." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[3] vals; int tag; }
            unittest {
                Outer[] arr = [Outer([1, 2, 3], 10)];
                arr[0].vals = [7, 8, 9];
                assert(arr[0].vals == [7, 8, 9]);
                assert(arr[0].tag == 10);
            }
        });
    }
}

// The same shape, but the rhs is an existing static-array lvalue rather than
// a literal: `compileStaticArrayValueInto` resolves both forms already, so
// this needs no further change beyond the literal case above.
static foreach (backend; Matrix!()) {
    @("dynamicArray.staticArrayFieldOfStructElementWrittenFromVariable." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[3] vals; int tag; }
            unittest {
                Outer[] arr = [Outer([1, 2, 3], 10)];
                int[3] existing = [4, 5, 6];
                arr[0].vals = existing;
                assert(arr[0].vals == [4, 5, 6]);
                assert(arr[0].tag == 10);
            }
        });
    }
}

// An *indexed* write into that same static-array field (`arr[i].fixedField[j]
// = value`): `staticArrayBaseOffset` resolved `arr[0].vals`'s base offset
// through `tryStructField`, which for a dynamic-array-of-structs element
// (`structBaseOffsetOrMaterialise`'s `dynamicArrayDescriptorOrNull` branch)
// returns a throwaway copy of the element with no writeback wiring at all --
// silently discarding the store instead of throwing. `arr[0].vals` (the whole
// field) previously used the same throwaway base for its own reads, but the
// whole-value *write* case above bypasses it via
// `tryStructSliceFieldElementFieldPointer`'s real pointer; this indexed case
// had no such bypass. Fixed by resolving the field's real runtime pointer the
// same way and advancing it by the index, mirroring
// `tryStaticArrayRuntimeAddress`'s pointer-advance for a plain static-array
// local.
static foreach (backend; Matrix!()) {
    @("dynamicArray.staticArrayFieldElementOfStructElementWritten." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[3] vals; int tag; }
            unittest {
                Outer[] arr = [Outer([1, 2, 3], 10)];
                arr[0].vals[1] = 99;
                assert(arr[0].vals[1] == 99);
                assert(arr[0].vals[0] == 1);
                assert(arr[0].vals[2] == 3);
                assert(arr[0].tag == 10);
            }
        });
    }
}

// The compound-assignment sibling of the indexed write above
// (`arr[i].fixedField[j] += value`): the identical silent-corruption shape.
// `compileAddAssignExpression`'s `IndexExp` handling
// (`tryStaticArrayElementAddAssign`) is a separate dispatch from
// `compileAssignExpression` and still resolved the field's base through the
// same throwaway `tryStructField` copy the plain-assignment case used to,
// silently discarding the increment instead of throwing. Fixed the same way:
// `tryArrayElementFieldIndexAddAssign` resolves the field's real runtime
// pointer and advances it by the index, then reads, adds, and stores back
// through that real address.
static foreach (backend; Matrix!()) {
    @("dynamicArray.staticArrayFieldElementOfStructElementAddAssigned." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[3] vals; int tag; }
            unittest {
                Outer[] arr = [Outer([1, 2, 3], 10)];
                arr[0].vals[1] += 5;
                assert(arr[0].vals[1] == 7);
                assert(arr[0].vals[0] == 1);
                assert(arr[0].vals[2] == 3);
                assert(arr[0].tag == 10);
            }
        });
    }
}

// A *doubly*-indexed write into a multi-dimensional static-array field
// (`arr[i].fixedField[j][k] = value`, e.g. `struct Outer { int[2][3] vals;
// int tag; }`): the same silent-corruption shape as the singly-indexed case
// above, one dimension deeper. `arr[0].vals[1]`'s own `IndexExp` is not a
// `DotVarExp`, so it fell through the singly-indexed fix's pattern match
// straight to `tryStaticArrayElement`'s `locateStaticArrayElement`, which
// resolves `arr[0].vals`'s base through `tryStructField`'s throwaway copy of
// the whole `arr[0]` element -- silently discarding the store instead of
// throwing. Fixed by generalising the singly-indexed fix into
// `arrayElementFieldPointer` (`compiler.d`), which recurses through any
// number of `IndexExp` layers, advancing the field's own real runtime
// pointer one dimension at a time via `advanceStaticArrayPointer` instead of
// ever falling through to the throwaway copy. Interpreter throws
// "Unsupported interpreter assignment target." on this doubly-indexed shape
// even though the singly-indexed sibling above already passes -- a separate,
// unconfirmed backend gap, not this fix's scope.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "Unsupported interpreter assignment target."),
)) {
    @("dynamicArray.nestedStaticArrayFieldElementOfStructElementWritten." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[2][3] vals; int tag; }
            unittest {
                Outer[] arr = [Outer([[1, 2], [3, 4], [5, 6]], 10)];
                arr[0].vals[1][0] = 99;
                assert(arr[0].vals[1][0] == 99);
                assert(arr[0].vals[0][0] == 1);
                assert(arr[0].vals[0][1] == 2);
                assert(arr[0].vals[1][1] == 4);
                assert(arr[0].vals[2][0] == 5);
                assert(arr[0].vals[2][1] == 6);
                assert(arr[0].tag == 10);
            }
        });
    }
}

// The compound-assignment sibling of the doubly-indexed write above
// (`arr[i].fixedField[j][k] += value`): the identical silent-corruption
// shape one dimension deeper than the singly-indexed compound-assignment
// fix. Fixed the same way, through the shared `arrayElementFieldPointer`.
// Interpreter throws the same "Unsupported interpreter assignment target."
// gap as the plain-assignment sibling above.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "Unsupported interpreter assignment target."),
)) {
    @("dynamicArray.nestedStaticArrayFieldElementOfStructElementAddAssigned." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[2][3] vals; int tag; }
            unittest {
                Outer[] arr = [Outer([[1, 2], [3, 4], [5, 6]], 10)];
                arr[0].vals[1][0] += 5;
                assert(arr[0].vals[1][0] == 8);
                assert(arr[0].vals[0][0] == 1);
                assert(arr[0].vals[2][1] == 6);
                assert(arr[0].tag == 10);
            }
        });
    }
}

// The `Tarray` sibling of the doubly-indexed static-array-field write above
// (`arr[i].matrixField[j][k] = value`, e.g. `int[][] matrixField`, a
// dynamic-array-of-dynamic-arrays field): `arrayElementFieldPointer` only
// resolved a `Tsarray` dimension, so this shape threw "Unsupported
// assignment in bytecode core" rather than corrupting anything, but it was
// still unsupported. Fixed by extending `arrayElementFieldPointer` (via
// `advanceArrayElementFieldPointer`) to also resolve a `Tarray` dimension:
// the field's own real pointer is dereferenced to load its `{pointer,
// length}` descriptor, and the same `advanceStaticArrayPointer` bounds-check
// and pointer arithmetic ordinary dynamic-array indexing already uses is fed
// that descriptor's runtime pointer and length instead of a frame address
// and a compile-time-constant length. Interpreter throws "Unsupported
// interpreter assignment target." on this shape, the same pre-existing gap
// as the `Tsarray` sibling above.
//
// The fixture builds `matrixField` from an intermediate `rows` local rather
// than an inline array-of-arrays literal passed directly as the constructor
// argument, exercising the plain descriptor-copy path
// (`dynamicArrayDescriptorOrNull`) rather than literal construction; the
// sibling block below exercises the literal directly.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "Unsupported interpreter assignment target."),
)) {
    @("dynamicArray.nestedDynamicArrayFieldElementOfStructElementWritten." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[][] matrixField; int tag; }
            unittest {
                int[][] rows = [[1, 2], [3, 4, 5], [6, 7]];
                Outer[] arr = [Outer(rows, 10)];
                arr[0].matrixField[1][2] = 99;
                assert(arr[0].matrixField[1][2] == 99);
                assert(arr[0].matrixField[0][0] == 1);
                assert(arr[0].matrixField[0][1] == 2);
                assert(arr[0].matrixField[1][0] == 3);
                assert(arr[0].matrixField[1][1] == 4);
                assert(arr[0].matrixField[2][0] == 6);
                assert(arr[0].matrixField[2][1] == 7);
                assert(arr[0].tag == 10);
            }
        });
    }
}

// An out-of-bounds index into the `Tarray` dimension throws, rather than
// corrupting memory: `advanceArrayElementFieldPointer`'s `Tarray` branch
// bounds-checks against the descriptor's own runtime length word
// (`Op.checkStaticArrayIndex`, the same check ordinary dynamic-array
// indexing raises), so this is druntime's ordinary `ArrayIndexError` text,
// byte for byte matching `SystemLinker`. `Ctfe`'s own bounds check uses the
// divergent backtick-range wording pinned below.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges, "see sibling pin below (Ctfe)"),
    Omit!(Interpreter, Because.unconfirmed,
        "Unsupported interpreter assignment target."),
)) {
    @("dynamicArray.nestedDynamicArrayFieldElementOutOfBoundsIndexThrows." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[][] matrixField; int tag; }
            unittest {
                int[][] rows = [[1, 2], [3, 4, 5]];
                Outer[] arr = [Outer(rows, 10)];
                arr[0].matrixField[1][5] = 99;
            }
        }).shouldThrowWithMessage(
            "index [5] is out of bounds for array of length 3",
        );
    }
}

static foreach (backend; AliasSeq!(Ctfe)) {
    @("dynamicArray.nestedDynamicArrayFieldElementOutOfBoundsIndexThrows." ~
        backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[][] matrixField; int tag; }
            unittest {
                int[][] rows = [[1, 2], [3, 4, 5]];
                Outer[] arr = [Outer(rows, 10)];
                arr[0].matrixField[1][5] = 99;
            }
        }).shouldThrowWithMessage("array index 5 is out of bounds `[0..3]`");
    }
}

// The construction-side sibling of the descriptor-copy fixture above: an
// array-of-arrays *literal* landing directly in a `Tarray` field slot
// (rather than through an existing dynamic-array local's descriptor copy).
// Five call sites built a field's descriptor via `compileDynamicArrayInto`
// without passing `arrayElementIsArray(fieldType)`, defaulting to `false`
// and mis-sizing the element width to the scalar (4-byte) width instead of
// the 16-byte slice-descriptor width a nested array element actually needs.
// Every heap write through the resulting descriptor then landed at the
// wrong address -- confirmed to SIGSEGV, not merely produce a wrong result.
// `compileStructLiteralInto` covers a struct literal built inline; the
// other four are its `compileAssignExpression`-reachable siblings.
static foreach (backend; Matrix!()) {
    @("dynamicArray.structLiteralArrayOfArraysFieldConstructedInline." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[][] matrixField; int tag; }
            unittest {
                Outer o = Outer([[1, 2], [3, 4, 5]], 10);
                assert(o.matrixField[1][2] == 5);
                assert(o.matrixField[0][1] == 2);
                assert(o.tag == 10);
            }
        });
    }

    @("dynamicArray.directFieldAssignmentOfArrayOfArraysLiteral." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[][] matrixField; int tag; }
            unittest {
                Outer o;
                o.matrixField = [[1, 2], [3, 4, 5]];
                assert(o.matrixField[1][2] == 5);
                assert(o.matrixField[0][1] == 2);
            }
        });
    }

    @("dynamicArray.arrayElementFieldAssignmentOfArrayOfArraysLiteral." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[][] matrixField; int tag; }
            unittest {
                Outer[] arr = [Outer(null, 0)];
                arr[0].matrixField = [[1, 2], [3, 4, 5]];
                assert(arr[0].matrixField[1][2] == 5);
                assert(arr[0].matrixField[0][1] == 2);
            }
        });
    }

    @("dynamicArray.structPointerFieldAssignmentOfArrayOfArraysLiteral." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Holder { int[][] matrixField; int tag; }
            unittest {
                Holder holder;
                Holder* carrier = &holder;
                carrier.matrixField = [[1, 2], [3, 4, 5]];
                assert(carrier.matrixField[1][2] == 5);
                assert(holder.matrixField[1][2] == 5);
            }
        });
    }

    @("dynamicArray.classPointerFieldAssignmentOfArrayOfArraysLiteral." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C { int[][] matrixField; }
            unittest {
                C c = new C();
                c.matrixField = [[1, 2], [3, 4, 5]];
                assert(c.matrixField[1][2] == 5);
                assert(c.matrixField[0][1] == 2);
            }
        });
    }
}

// A doubly-indexed *element* write into a class field of array-of-arrays
// type (`a.m[0][0] = 99`), with no intervening struct/field dot or
// array-of-structs element unlike every `matrixField` shape above --
// distinct from the whole-field-literal-assignment shape just above (which
// never indexes at all) and from the `arr[i].matrixField[j][k]` shapes
// further up (whose outer base is an array element, not a bare class-typed
// local). Previously threw "Unsupported assignment in bytecode core":
// `innerArrayDescriptor`'s outer-array resolution only recognised a plain
// `VarExp` local, rejecting `a.m`'s `DotVarExp` base outright. Fixed by
// giving `innerArrayDescriptor` a narrow, explicitly-`Tarray`-gated branch
// (`dynamicArrayFieldDescriptorOrNull`, shared with
// `dynamicArrayDescriptorOrNull`'s own `DotVarExp` dispatch) for a
// class/struct-field base, rather than a blanket recursive call into
// `dynamicArrayDescriptorOrNull` -- the latter also makes that function's
// later, ungated `staticArrayOffsetOf` branch reachable for unrelated
// static-array-of-structs shapes, corrupting
// `nestedStaticArrayFieldElementOfStructElementAddAssigned`'s stride.
// Interpreter throws "Unsupported interpreter assignment target." on this
// shape, the same pre-existing gap as the doubly-indexed siblings above.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "Unsupported interpreter assignment target."),
)) {
    @("dynamicArray.classFieldDoublyIndexedElementWritten." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            class C { int[][] m; }
            unittest {
                C a = new C();
                a.m = [[1, 2], [3, 4, 5]];
                a.m[0][0] = 99;
                assert(a.m[0][0] == 99);
                assert(a.m[0][1] == 2);
                assert(a.m[1][0] == 3);
                assert(a.m[1][2] == 5);
            }
        });
    }
}

// A sibling of the five-call-site fix above, in a field-construction path
// distinct from all five: a constructor-less struct's positional
// `new S(args)` construction (`initialiseStructFields`), which also called
// `compileDynamicArrayInto` for a `Tarray` field without
// `arrayElementIsArray(field.type)`, defaulting to `false` and mis-sizing
// an array-of-arrays field's element width -- confirmed via real `bin/ut`
// to SIGSEGV. Fixed by passing `arrayElementIsArray(field.type)`.
static foreach (backend; Matrix!()) {
    @("dynamicArray.structPositionalConstructionOfArrayOfArraysLiteral." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            struct Outer { int[][] matrixField; int tag; }
            unittest {
                auto o = new Outer([[1, 2], [3, 4, 5]], 10);
                assert(o.matrixField[1][2] == 5);
                assert(o.matrixField[0][1] == 2);
                assert(o.tag == 10);
            }
        });
    }
}

// A broader-surface sibling of the same shape: `emitCallArgument`'s
// by-value `Tarray`-parameter branch resolves an argument's descriptor via
// `arrayDescriptorOffset` without passing `arrayElementIsArray(argument.
// type)` either, so an inline array-of-arrays literal passed directly as a
// function-call argument mis-sizes the same way -- confirmed via real
// `bin/ut` to SIGSEGV. Fixed by passing `arrayElementIsArray(argument.
// type)`.
static foreach (backend; Matrix!()) {
    @("dynamicArray.functionCallArgumentArrayOfArraysLiteral." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int sumInner(int[][] m, int idx) {
                return m[idx][2];
            }
            unittest {
                assert(sumInner([[1, 2], [3, 4, 5]], 1) == 5);
            }
        });
    }
}

// Two more siblings of the identical shape, both in `compileConcatenationAssign`
// (`arr ~= other`): the local-variable branch and the module-variable branch
// each resolve the right-hand side's descriptor via `arrayDescriptorOffset`
// without passing `elementIsArray`, mis-sizing an array-of-arrays right-hand
// side that is not already a known local (a literal, here) -- confirmed via
// real `bin/ut` to SIGSEGV in both branches. Fixed by threading
// `elementIsArray` (the LHS descriptor's own, in each branch) through.
static foreach (backend; Matrix!()) {
    @("dynamicArray.catAssignArrayOfArraysLiteralIntoLocal." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[][] arr = [[1, 2]];
                arr ~= [[9, 9], [8, 8]];
                assert(arr.length == 3);
                assert(arr[1][0] == 9);
                assert(arr[2][1] == 8);
            }
        });
    }
}

// The module-variable branch needs its own `Matrix`: `Ctfe` cannot read a
// mutable static variable at compile time at all (a genuine D CTFE
// restriction, confirmed with real `dmd`: "static variable `arr` cannot be
// read at compile time"), independent of this fix.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a mutable static/module variable"),
)) {
    @("dynamicArray.catAssignArrayOfArraysLiteralIntoModuleVariable." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[][] arr;
            unittest {
                arr ~= [[9, 9], [8, 8]];
                assert(arr.length == 2);
                assert(arr[0][0] == 9);
                assert(arr[1][1] == 8);
            }
        });
    }
}

// A concatenation sibling of the same shape: `catOperandDescriptor` (via
// `compileCatInto`, for `a ~ b`) also resolved a `Tarray` operand's
// descriptor via `arrayDescriptorOffset` without passing `elementIsArray`,
// mis-sizing an array-of-arrays literal operand not already a known local
// -- confirmed via real `bin/ut` to SIGSEGV. Fixed by threading the
// concatenation's own `elementIsArray` through `catOperandDescriptor`.
static foreach (backend; Matrix!()) {
    @("dynamicArray.catArrayOfArraysLiteralOperand." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            unittest {
                int[][] a = [[1, 2]];
                auto c = a ~ [[3, 4], [5, 6]];
                assert(c.length == 3);
                assert(c[2][1] == 6);
                assert(c[1][0] == 3);
            }
        });
    }
}

// A read-side sibling: `dynamicArrayDescriptorOrNull`'s array-returning-call
// branch (an array-returning call indexed directly, e.g. `f()[i]`, or as the
// inner operand of a further index, e.g. `f()[i][j]`) also built its
// `DynamicArrayLocal`/materialised its descriptor via `compileDynamicArrayInto`
// without `arrayElementIsArray(expression.type)`, mis-sizing a call that
// returns an array-of-arrays -- confirmed via real `bin/ut` to throw a wrong
// "index out of bounds" (the outer descriptor's length read as 0). Fixed by
// passing `arrayElementIsArray(expression.type)` both to
// `compileDynamicArrayInto` and into the resulting `DynamicArrayLocal`.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "wrong result indexing an array-of-arrays-returning call's result"),
)) {
    @("dynamicArray.arrayOfArraysReturningCallResultIndexing." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        runBackendSourceFixtureTests!backend(q{
            int[][] matrixMaker() {
                return [[1, 2], [3, 4, 5]];
            }
            unittest {
                assert(matrixMaker()[1][2] == 5);
                assert(matrixMaker()[0][1] == 2);
            }
        });
    }
}

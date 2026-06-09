# Plan: Grow the CTFE Oracle Corpus With Untested D Features

## Why this plan exists

An earlier effort used `Ctfe` line-coverage reports to drive new tests. It hit
diminishing returns: most of the remaining uncovered lines were
assertion-message and diagnostic-formatting branches, so each test lit up one
more error string and proved almost no real behaviour. Line coverage rewards
touching lines, not exercising semantics — a backend can be green on the whole
matrix and still have no working arithmetic, because `1 + 2` is folded to `3`
before any backend runs it.

The goal here is the opposite: **add tests for real D language behaviours the
corpus does not test yet.** `Ctfe` (`source/quickbite/backends/ctfe/dmd_ctfe.d`)
runs each snippet through dmd's CTFE engine and is the canonical correctness
oracle. A test written against CTFE passes by construction (it is real D), and
once it exists it becomes a hard requirement that every other backend must
satisfy when the test is promoted. So every behaviour we add to the CTFE corpus
is both new oracle coverage and a future cross-backend obligation. That is the
thing we actually want: confidence that a backend which passes the suite is
correct, not just that its lines were executed.

## What an agent should do

Work one feature area at a time, smallest first. For each:

1. Pick the next unchecked item from the **Feature backlog** below.
2. Confirm dmd CTFE actually supports it (it supports essentially all pure
   computation; it rejects real `malloc`, I/O, and impure runtime calls — those
   become unsupported-diagnostic tests instead, see below).
3. Write the fixture(s) in the right file under `tests/ut/backends/lang/`
   (see **Where tests go**), inside a `static foreach (backend; backends)`
   block — `backends` is `Ctfe` only, which is the target.
4. **Verify the expected value against CTFE before finalising it.** CTFE is the
   oracle; the expected result/message must be whatever CTFE actually produces,
   not what we assume. For results that need empirical confirmation (`int.min /
   -1`, exact null-struct-field rendering, whether `^^` folds), run it through
   `Ctfe` first and pin the assertion to the observed output.
5. Run the focused test, then `dub test -- --random`.
6. Tick the item and move on.

Do **not** promote these tests to other backends as part of this plan; that is
separate downstream work. This plan only grows the CTFE corpus.

## Rules every fixture must follow

These come from `ai/mistakes.md` and AGENTS.md and are non-negotiable:

- **No constant folding.** Use runtime-shaped operands: mutable locals, values
  returned from small helper functions, or function parameters. Never bare
  literals in the expression under test — dmd folds `1 + 2` to `3` before the
  test means anything. Pattern: `int one() { return 1; } ... assert(one() + 41
  == 42);`.
- **No variadic functions** as fixtures; they pull in varargs constructs that
  fail before the behaviour under test is reached.
- **Omit empty parens**: `doStuff;` not `doStuff();`, including inside `q{...}`.
- **No host-test asserts inside `q{...}`.** The fixture's own `unittest` block
  does the asserting; the harness reports its pass/fail.
- **Floating-point assertion-failure messages must be `@ShouldFail`.** druntime's
  CTFE assert formatter emits `<double not supported>`, so a *failing* float
  assert cannot have its message compared. Passing float asserts are fine; for
  failure-message tests on floats, mark the test `@ShouldFail` (see existing
  `math.d`).
- **TDD / approval gate.** Adding a new test requires user approval first. Show
  the exact fixture code in a syntax-highlighted block and stop for approval
  before writing it. (Promoting an existing CTFE test to another backend is the
  only pre-approved move, and that is not what this plan does.)
- **Never weaken a test to make it pass.** If CTFE rejects something we thought
  it supported, convert it to an unsupported-diagnostic test and keep the inner
  supported assertion.

## Where tests go

Add to the existing feature file; create a new file only if no area fits.

| Feature area | File |
|---|---|
| switch / loops / foreach / goto | `tests/ut/backends/lang/control_flow.d` |
| structs, operator overloading | `tests/ut/backends/lang/structs.d` |
| exceptions, catch hierarchy | `tests/ut/backends/lang/exceptions.d` |
| integer width / sign / wraparound | `tests/ut/backends/lang/integrals.d` |
| binary/unary ops, shifts, modulo | `tests/ut/backends/lang/expressions.d` |
| arrays, slices, AAs | `tests/ut/backends/lang/arrays.d` |
| math intrinsics | `tests/ut/backends/lang/math.d` |
| struct/null value round-trip (REPL) | `tests/ut/backends/api/repl.d` |

The fixture helper is `runBackendSourceFixtureTests!backend(q{...})` (asserts via
the fixture's own `unittest`, surfaced through `.shouldThrowWithMessage` for
failure tests). For value round-tripping that must marshal a whole struct or a
`null` result, use the REPL driver (`runReplLoop`) — see the marshaling section.

## Feature backlog (highest behavioural value first)

These are real D semantics the corpus does not exercise. Each `[ ]` is one
slice. Fixtures below are starting points; the agent confirms the exact
expected value against CTFE before writing.

### Tier 1 — most likely to expose a real backend bug later

- [ ] **String switch.** Entirely distinct lowering from int switch; absent.
  ```d
  string pick(int n) { return n == 1 ? "red" : "green"; }
  int classify(string s) {
      switch (s) {
          case "red": return 10;
          case "green": return 20;
          default: return 0;
      }
  }
  unittest {
      assert(classify(pick(1)) == 10);
      assert(classify(pick(2)) == 20);
  }
  ```

- [ ] **Default struct equality (field-wise `==`).** No struct `==` anywhere.
  ```d
  struct Point { int x; int y; }
  Point make(int seed) { Point p; p.x = seed; p.y = seed + 1; return p; }
  unittest {
      assert(make(3) == make(3));
      assert(make(3) != make(4));
  }
  ```

- [ ] **Custom `opEquals`.** No operator overloads tested at all.
  ```d
  struct CaseId {
      int id;
      bool opEquals(in CaseId other) const { return id == other.id; }
  }
  CaseId make(int seed) { CaseId c; c.id = seed; return c; }
  unittest {
      assert(make(7) == make(7));
      assert(make(7) != make(8));
  }
  ```

- [ ] **Catch a derived exception by base type + read a subclass field.**
  ```d
  class MyError : Exception {
      int code;
      this(int c) { super("boom"); code = c; }
  }
  int run(int seed) {
      try {
          if (seed > 0) throw new MyError(seed + 40);
          return 0;
      } catch (Exception e) {
          return (cast(MyError) e).code;
      }
  }
  unittest { assert(run(2) == 42); }
  ```

- [ ] **Signed/unsigned comparison conversion.** `-1 < 0u` is *false* in D.
  ```d
  int neg() { return -1; }
  uint zero() { return 0u; }
  unittest { assert(!(neg() < zero())); }
  ```

- [ ] **Integer wraparound at type boundaries.**
  ```d
  int top() { return int.max; }
  uint bottom() { return 0u; }
  unittest {
      int a = top();   assert(a + 1 == int.min);
      uint b = bottom(); assert(b - 1 == uint.max);
  }
  ```

### Tier 2 — common semantics, clear gaps

- [ ] **Negative / unsigned modulo sign rule.** `-7 % 3 == -1` (sign follows
  dividend). Corpus only has positive modulo.
- [ ] **`>>>` zero-fill vs `>>` sign-extend.**
  ```d
  int seed() { return -1; }
  unittest {
      int v = seed();
      assert((v >> 28) == -1);
      assert((v >>> 28) == 15);
  }
  ```
- [ ] **`final switch` on an enum** (must cover all members).
- [ ] **`switch` case ranges** (`case 0: .. case 3:`) and multi-value cases.
- [ ] **Default function arguments** (`int add(int a, int b = 10)`).
- [ ] **Overload resolution by signature** (`kind(int)` vs `kind(double)`).
- [ ] **`foreach` with index** `(i, e)` over a runtime array.
- [ ] **`foreach_reverse`** over a runtime array/range.
- [ ] **Nested struct field access** (`outer.inner.v`).
- [ ] **Runtime AA insertion / growth** (`m[k] = v` building the map,
  overwrite, `.length`). Corpus only tests literal AAs + lookup.

### Tier 3 — fills out existing-but-thin areas

- [ ] **More operator overloads**: `opCmp`, `opBinary`, `opIndex`, `opUnary`,
  `opAssign`.
- [ ] **Exception extras**: rethrow (`throw;`), multiple typed `catch` clauses
  selecting by type, `Error` vs `Exception` distinction.
- [ ] **Integer edge cases needing CTFE confirmation**: `int.min / -1`,
  `int.min % -1` (CTFE may reject as overflow — if so, make it an
  unsupported-diagnostic test, keeping the inner supported assertion).
- [ ] **`^^` power operator** on integers — confirm CTFE doesn't just fold it
  before deciding how to shape the fixture.
- [ ] **`float`/`real` variants** of the math intrinsics already tested only for
  `double`; passing forms only (failure-message forms need `@ShouldFail`).
- [ ] **Array extras**: `.dup`/`.idup` of a dynamic array, `.ptr`, jagged
  multidimensional arrays.

### Tier 4 — value marshaling round-trip (REPL-driven)

The CTFE marshaling for **whole struct values and `null` results** is never
exercised: tests evaluate `.field` ints, never a struct or a `null`. These need
the REPL driver because only `eval`/`evalRepl` reach `structValue`,
`isFunctionLikeType`, and `Value.null_`. Each new struct shape also covers a
distinct skip path in `dmd_ctfe.d`. Verify the exact rendered string against
CTFE before pinning it.

- [ ] **Struct value result** — covers `structValue` + `structLiteralField`.
  REPL: declare `struct Point { int x; int y; }`, runtime locals `a`, `b`,
  evaluate `Point(a, b)`, expect the CTFE-rendered struct string.
- [ ] **Array of structs** — `arrayValue` recursing into `structValue`.
- [ ] **Struct with a null function-pointer field** — `isFunctionLikeType`
  pointer-to-function arm (field is skipped).
- [ ] **Struct with a null delegate field** — `isFunctionLikeType` delegate arm.
- [ ] **Struct with a null class/pointer field** — kept as `Value.null_`; the
  only path that produces a `null` result. Confirm CTFE's rendering.
- [ ] **Nested struct with a synthetic `this` context field** —
  `isSyntheticThisField`. Trickiest; confirm dmd actually synthesises the
  context field in the CTFE literal before relying on it.
- [ ] **Assoc array with struct values** — `assocArrayValue` into `structValue`.

## Known dead / unreachable code (do not write tests for these)

Flag for possible deletion instead of trying to cover:

- `evalReplTypeSource` in `dmd_ctfe.d` — never called; type names come from the
  REPL layer.
- The `incomplete` arm of `Ctfe.evalRepl` — unreachable through the REPL driver
  (guarded upstream).
- The `type is null` early returns in `frontend/dmd/values.d` — CTFE results are
  always typed, so these cannot fire from the oracle path.

Covering dead branches is exactly the diminishing-returns trap this plan
exists to avoid.

## Definition of done

The corpus tests every behaviour in Tiers 1–3 against CTFE, and the struct/null
marshaling round-trips in Tier 4 are covered via the REPL. At that point
"passes the suite" means "agrees with the dmd oracle across real D semantics,"
which is the confidence we were missing.

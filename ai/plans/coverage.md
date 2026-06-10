# Plan: Backend Semantic Confidence

## Why this plan exists

The end goal is that any backend — `Interpreter`, `Bytecode`, `IR`,
`SystemLinker` — could be dropped in where dmd's CTFE engine or regular
dmd-compiled code runs today, and nobody would notice. "Passes the test
suite" must come to *mean* that. Today it does not, for two independent
reasons:

1. **The corpus has semantic holes.** Real D behaviours (string switch,
   operator overloading, signed/unsigned conversion, integer wraparound,
   struct/null value marshaling, …) are not tested against any backend.
2. **The matrix is opt-in and uneven.** `backends` (in
   `tests/ut/backends/package.d`) is `Ctfe` only; each test block opts
   other backends in via `backendsWith!(...)`. Participation today:
   ~55 multi-backend blocks omit `IR`, only ~14 include `SystemLinker`,
   and whole files (e.g. `cerealed.d`) run on `Ctfe` alone. Nothing
   reports these gaps, so "green" silently means different things per
   backend.

Two failed approaches inform this plan. Line coverage of `Ctfe` was
tried as the test-idea generator and hit diminishing returns fast: the
uncovered remainder is dmd's diagnostic-formatting branches, and each
new test lit up one error string while proving no behaviour. More
fundamentally, coverage answers "did tests execute this line?" when the
question that matters is "**if this code were wrong, would any test
notice?**" — and a hand-curated backlog of feature ideas (the second
attempt) is a fish, not a fishing rod: once consumed, the agent has no
method for finding the next gap.

So this plan is built around three *generative* mechanisms that tell an
agent what test to write next without anyone imagining it (stream A),
plus matrix-gap visibility (stream B) and `IR` parity (stream C).
Expanding `SystemLinker`'s matrix is owned by `ai/plans/dmd-backend.md`,
not duplicated here — but every test added here becomes an obligation
that plan inherits.

## What "drop-in replacement" means

A backend is a drop-in replacement when, for every fixture in the
corpus, its observable behaviour is indistinguishable from the oracle's:

- the same unittests pass and fail;
- failing tests produce the **exact same messages** (assert messages,
  diagnostics);
- evaluated values (REPL/eval path) render identically;
- anything the backend cannot do is an **explicit unsupported
  diagnostic** — never a wrong answer, never a silent skip, never
  delegation to another backend (per `ai/plans/overview.md`).

## Oracle hierarchy

1. **Compiled code is ground truth.** Where real dmd codegen runs a
   fixture (via `SystemLinker`, or an actual compiled binary when
   needed to settle a dispute), its behaviour — including exact message
   text — is definitive. No "CTFE quirk" excuses for native results.
2. **CTFE is the working oracle** (`Ctfe`,
   `source/quickbite/backends/ctfe/dmd_ctfe.d`) for everything compiled
   code hasn't been brought to yet. A fixture written against CTFE
   passes by construction (it is real D) and becomes a cross-backend
   obligation when promoted.
3. **Disagreements:** backend vs CTFE → assume the backend or the test
   is wrong unless compiled D code proves otherwise. CTFE vs compiled
   code → compiled code wins; pin the compiled behaviour where the
   backend targets native semantics, and record the divergence in a
   comment next to the test (the known one: druntime's CTFE assert
   formatter emits `<double not supported>` for float failure
   messages).

## Stream A — generate new tests

Three mechanisms, in complementary roles:

- the **spec walk** enumerates what *should* be tested (breadth);
- **dmd test-suite mining** cheaply imports battle-tested edge cases
  (depth without imagination);
- **backend mutation** measures whether the resulting corpus would
  actually catch a wrong backend — it is both a generator and the exit
  criterion.

The hand-curated **starter backlog** at the end of this plan remains
valid work; consume it first, but do not extend it by imagination —
extend the corpus through the mechanisms below.

Every new test, regardless of which mechanism produced it, follows the
same finishing steps: verify the expected value/message against the
oracle empirically before pinning it; show the fixture and stop for
approval (the approval gate); after it passes on `Ctfe`, promote it to
`Interpreter`, `Bytecode`, and `IR` via `backendsWith!` (promotion is
pre-approved); run `ninja bin/ut` then `bin/ut --random`.

### A1. Backend mutation (generator + exit criterion)

The direct replacement for coverage as a measurement. A surviving
mutant is a *proof* that the corpus would not notice a wrong backend at
that point — exactly one new test, with a built-in demonstration that
it matters.

The loop (work in a worktree; never commit a mutant):

1. Pick a semantic site in `source/quickbite/backends/interpreter/`,
   `bytecode/`, or `ir/`. Do **not** mutate `ctfe/` (a thin wrapper
   over dmd — mutating it tests dmd, not us) or `native/` (codegen is
   dmd's).
2. Apply **one** plausible mutation. Good mutation operators:
   - swap operands of a non-commutative op (`a - b` → `b - a`,
     `a % b` → `b % a`);
   - off-by-one a comparison (`<` → `<=`, `>` → `>=`);
   - swap sign-extension for zero-extension (or `>>` for `>>>`);
   - widen/narrow a truncation (`cast(byte)` → `cast(short)`);
   - swap short-circuit behaviour (`&&` evaluates RHS eagerly);
   - drop a wraparound, negate a condition, return the wrong operand
     from min/max-style logic, skip the last loop iteration.
3. `ninja bin/ut && bin/ut` — full suite, since the point is whether
   *any* existing test notices.
4. **Mutant killed** (a test fails): the corpus covers that behaviour.
   Revert, record the site/mutation/outcome in the ledger, continue.
5. **Mutant survives** (suite green): a real gap. Design the fixture
   that the oracle verifies and the mutant fails; go through the
   approval gate; confirm the new test **fails with the mutant applied
   and passes without it** (the exposing-test discipline); revert the
   mutant; record; commit only the test.
6. **Equivalent mutant** (cannot change observable behaviour, e.g.
   commutative-op operand swap): record as equivalent, pick again.

Record-keeping: a checked-in ledger at `tests/coverage/mutants.md` —
one line per attempt: file:line, mutation, killed/survived/equivalent,
and the test that kills it. Agents read it first so the same mutant is
never retried, and the kill rate over time is the confidence metric.

Synergy with stream C: a mutant in `IR` can only be killed by a test
block that includes `IR`. A low kill rate in one backend is often a
matrix gap, not a corpus gap — check the stream-B report before
writing a new fixture.

### A2. Spec walk (enumerable checklist)

The D spec is a finite list of normative claims about semantics. Walk
it section by section; the checklist is the resumable cursor.

Artifact: `ai/plans/spec-checklist.md`, listing every spec section
(dlang.org/spec — expressions, statements, types, arithmetic, arrays,
hash-map, struct, class, enum, function, operator overloading, …) with
a status: `[ ]` open, `[x]` done, `n/a` (not pure-computation
semantics: modules, ABI, attributes-only sections, `version`, ImportC,
…). Create it as the first spec-walk action by enumerating the spec's
table of contents.

The loop:

1. Take the next open section.
2. Extract its testable normative claims — statements of the form
   "X evaluates to / converts to / is an error" about pure
   computation. Skip claims CTFE cannot run (record them in the
   checklist as deferred-to-native).
3. For each claim, grep the corpus (`tests/ut/backends/runner/`) for
   an existing test. Misses become proposed fixtures (approval gate,
   oracle-verified, then promoted).
4. Tick the section with a one-line note of what was added or why
   nothing was needed.

"Done" is well-defined: the spec ran out.

### A3. dmd test-suite mining

dmd's own tests (`compiler/test/runnable/`, `compiler/test/compilable/`
in the dmd repo) are thousands of fixtures, each written because
something once broke in a real compiler — accumulated edge cases nobody
imagines from scratch.

Setup: a local clone of dmd, checked out at the tag matching the
`dmd:frontend` dub dependency (2.112.x). One-time network access —
request approval per AGENTS.md.

The loop:

1. Pick the next unmined file (track progress in
   `tests/coverage/dmd-mining.md`: file, harvested / nothing-usable,
   which fixtures came from it).
2. Filter for pure computation: no I/O, no `printf`/`main`-driven
   output checking, no runtime-only features, no compiler-internals
   testing. Most of a `runnable/` file is usually unusable; the few
   usable assertions per file are the harvest.
3. Adapt the keepers to the fixture rules (wrap in `unittest`,
   runtime-shaped operands, omit empty parens) and to the right corpus
   file. Approval gate applies — these are new tests.
4. Verify against the oracle as usual (the upstream test passing under
   dmd is strong evidence, but our fixture is a rewrite — re-verify).

Prioritise `runnable/` files named after language areas the spec walk
or mutation work flags as thin (e.g. `arrayop`, `switch`, `bitops`,
`structlit`, `xtest46`-style grab-bags).

### Where tests go

| Feature area | File (under `tests/ut/backends/runner/ct/`) |
|---|---|
| switch / loops / foreach / goto | `control_flow.d` |
| structs, operator overloading | `structs.d` |
| exceptions, catch hierarchy | `exceptions.d` |
| integer width / sign / wraparound | `integrals.d` |
| binary/unary ops, shifts, modulo | `expressions.d` |
| arrays, slices, AAs | `arrays.d` |
| math intrinsics | `math.d` |
| boolean / short-circuit logic | `logic.d` |
| assert/diagnostic messages | `diagnostics.d` |
| impure / runtime-only (unsupported) | `../rt/` |
| struct/null value round-trip | REPL driver, `tests/ut/bin/repl/` |

The fixture helper is `runBackendSourceFixtureTests!backend(q{...})`
(the fixture's own `unittest` asserts; failures surface through
`.shouldThrowWithMessage`). Value round-trips that must marshal a whole
struct or a `null` use the REPL driver (`runReplLoop`).

### Fixture rules (non-negotiable, from `ai/mistakes.md` / AGENTS.md)

- **No constant folding.** Runtime-shaped operands only: mutable
  locals, helper-function returns, parameters. Never bare literals in
  the expression under test — dmd folds `1 + 2` before any backend
  runs. Pattern: `int one() { return 1; } … assert(one() + 41 == 42);`.
- **No variadic functions** as fixtures.
- **Omit empty parens**: `doStuff;`, including inside `q{...}`.
- **No host-test asserts inside `q{...}`** — the fixture's `unittest`
  does the asserting.
- **Float assertion-failure messages are `@ShouldFail` on the CTFE
  matrix** (the `<double not supported>` quirk above). Passing float
  asserts are fine.
- **Approval gate.** Show the exact fixture in a syntax-highlighted
  block and stop for approval before writing it. Promoting an existing
  test to another backend is the only pre-approved move.
- **Never weaken a test to make it pass.** If CTFE rejects something,
  convert to an unsupported-diagnostic test and keep the inner
  supported assertion.

## Stream B — make the matrix gaps visible

The matrix stays opt-in (`backendsWith!`); what changes is that the
gaps stop being invisible. Deliverable: a small checked-in script
(`scripts/matrix-report.sh` or similar) that scans
`tests/ut/backends/` for `static foreach (backend; backends…)` blocks
and emits a per-backend participation report:

- per backend: how many of the N test blocks include it;
- per file: which blocks exclude which backends;
- run on demand (and from `ci.sh`), output as a markdown table so
  diffs of the committed report show matrix regressions.

Implementation can be a grep/awk pass over the test sources — the
`backendsWith!(…)` text and the `@("name." ~ backend.stringof)` naming
convention make blocks mechanically identifiable. No build-system
integration required to start; correctness of the count matters more
than elegance.

A new test block that omits a backend is then a visible, reviewable
choice instead of a silent default.

## Stream C — IR to full parity

`IR` is a first-class target and must reach the same participation as
`Interpreter` and `Bytecode`. Promotion of an existing CTFE-backed
matrix test to another backend is pre-approved (AGENTS.md), so this
stream needs no test-approval round-trips:

1. Generate the stream-B report; take the list of blocks that have
   `Interpreter`/`Bytecode` but not `IR` (~55 today, concentrated in
   the `backendsWith!(Interpreter, Bytecode)` blocks).
2. One block at a time: add `IR`, run the focused test.
3. If it passes, commit and continue. If it fails, that is a found
   bug: write nothing new — the promoted test *is* the failing test —
   and fix the IR backend until green (strict TDD).
4. If the behaviour is genuinely unsupported by IR's current design,
   pin an explicit unsupported-diagnostic expectation for IR rather
   than leaving it out silently — same policy as the `rt/cstdlib.d`
   malloc tests.
5. Full suite (`bin/ut --random`) after every editing session.

## Out of scope (deliberately)

- **SystemLinker matrix expansion** — owned by
  `ai/plans/dmd-backend.md`. This plan only feeds it obligations.
- **Inverting the matrix default** to all-backends opt-out — revisit
  once the report exists and IR parity lands.
- **Differential fuzzing** (random program generation) — a possible
  future stream once mutation kill rates plateau, not part of this
  plan.
- **Dead/unreachable code** — do not write tests for:
  `evalReplTypeSource` in `dmd_ctfe.d` (never called), the
  `incomplete` arm of `Ctfe.evalRepl` (guarded upstream), the
  `type is null` early returns in `frontend/dmd/values.d` (CTFE
  results are always typed). Flag for deletion instead. Covering dead
  branches is the diminishing-returns trap this plan replaced.

## Definition of done

- The starter backlog (below) is consumed.
- The spec checklist exists and every applicable section is ticked.
- The mutation ledger shows **20 consecutive plausible mutants per VM
  backend all killed** — the loop-until-dry signal that the corpus is
  strong, not just well-trodden.
- The matrix report exists, runs in `ci.sh`, and shows `IR` at parity
  with `Interpreter`/`Bytecode`.

At that point "passes the suite" means "agrees with the dmd oracle
across real D semantics, on every VM backend, with a measured kill
rate behind it" — which is the confidence this plan exists to provide.
The remaining distance to full drop-in status is then exactly the
`SystemLinker` matrix work in `ai/plans/dmd-backend.md`.

## Appendix: starter backlog (hand-curated; consume, don't extend)

Known gaps found by inspection. Each `[ ]` is one slice; sketches are
starting points — confirm the exact expected value against the oracle
before writing. When this list is empty, new work comes from A1–A3
only.

### Tier 1 — most likely to expose a real backend bug

- [ ] **String switch.** Entirely distinct lowering from int switch;
  absent.
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
- [ ] **Default struct equality (field-wise `==`).** No struct `==`
  anywhere.
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
- [ ] **Catch a derived exception by base type + read a subclass
  field.**
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
- [ ] **Signed/unsigned comparison conversion.** `-1 < 0u` is *false*
  in D.
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

- [ ] **Negative modulo sign rule.** `-7 % 3 == -1` (sign follows the
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
- [ ] **`switch` case ranges** (`case 0: .. case 3:`) and multi-value
  cases.
- [ ] **Default function arguments** (`int add(int a, int b = 10)`).
- [ ] **Overload resolution by signature** (`kind(int)` vs
  `kind(double)`).
- [ ] **`foreach` with index** `(i, e)` over a runtime array.
- [ ] **`foreach_reverse` over a runtime int array** (covered today
  only for `dchar` over a string).
- [ ] **Nested struct field access** (`outer.inner.v`).
- [ ] **Runtime AA insertion / growth** (`m[k] = v` building the map,
  overwrite, `.length`). Corpus only tests literal AAs + lookup, plus
  AA `.dup`.

### Tier 3 — fills out existing-but-thin areas

- [ ] **More operator overloads**: `opCmp`, `opBinary`, `opIndex`,
  `opUnary`, `opAssign`.
- [ ] **Exception extras**: rethrow (`throw;`), multiple typed `catch`
  clauses selecting by type, `Error` vs `Exception` distinction.
- [ ] **Integer edge cases needing oracle confirmation**:
  `int.min / -1`, `int.min % -1` (CTFE may reject as overflow — if so,
  unsupported-diagnostic test, keeping the inner supported assertion).
- [ ] **`^^` power operator** on integers — confirm it isn't folded
  before deciding the fixture shape.
- [ ] **`float`/`real` variants** of the math intrinsics tested only
  for `double`; passing forms only.
- [ ] **Array extras**: `.dup`/`.idup` of a dynamic array (only AA
  `.dup` is covered), `.ptr`, jagged multidimensional arrays.

### Tier 4 — value marshaling round-trip (REPL-driven)

CTFE marshaling of **whole struct values and `null` results** is never
exercised: tests evaluate `.field` ints, never a struct or a `null`.
These need the REPL driver because only the eval path reaches
`structValue`, `isFunctionLikeType`, and `Value.null_` in
`dmd_ctfe.d`. Verify the exact rendered string against the oracle
before pinning it.

- [ ] **Struct value result** — declare `struct Point { int x; int y;
  }`, runtime locals `a`, `b`, evaluate `Point(a, b)`.
- [ ] **Array of structs** — `arrayValue` recursing into
  `structValue`.
- [ ] **Struct with a null function-pointer field** — pointer-to-
  function arm of `isFunctionLikeType` (field is skipped).
- [ ] **Struct with a null delegate field** — delegate arm.
- [ ] **Struct with a null class/pointer field** — kept as
  `Value.null_`; the only path producing a `null` result.
- [ ] **Nested struct with a synthetic `this` context field** —
  `isSyntheticThisField`. Confirm dmd actually synthesises it in the
  CTFE literal first.
- [ ] **Assoc array with struct values** — `assocArrayValue` into
  `structValue`.

# Plan: Backend Semantic Confidence

## Status (2026-07-06)

The starter backlog (appendix) is fully consumed (tiers 1–4; PRs #210,
#213, #214, #216). None of the three generative mechanisms below has
been started: no `tests/coverage/mutants.md`, no
`ai/plans/spec-checklist.md`, no `tests/coverage/dmd-mining.md`. Of the
definition-of-done gates, only the backlog gate is met.

Scheduling decision:

- **A2 (spec walk) and A3 (dmd test-suite mining) are parked.** The
  active density generator right now is `ai/plans/interpreter.md`'s
  empirical gap inventory from real dub packages, which produces
  oracle-backed fixtures from constructs real code actually uses —
  higher yield per fixture than a spec walk while the Interpreter still
  has known gaps. Revisit parking when interpreter.md's per-package
  inventories stop producing new fixture classes.
- **A1 (backend mutation) is queued with a named consumer: run it
  against `BytecodeNewCore` before the bytecode engine-default flip**
  (`bytecode.md`). The ratchet proves the new core passes what the old
  core passed; A1's kill criterion asks the different question of
  whether the matrix actually constrains the new core's behaviour —
  worth asking before the old core is deleted, given the new core's
  admitted latent stack-reserve/`&local` issue that the matrix never
  caught. If the flip proceeds without A1, that waiver belongs in
  `bytecode.md`'s flip gate, not in silence.

## Goal

Given that quickbite's tests pass, any D code should behave on every
backend — `Interpreter`, `Bytecode`, `IR`, `SystemLinker` — exactly as
it would if compiled into object files, linked, and run as a native
program. "Passes the test suite" must come to *mean* that.

This plan owns the **corpus**: making the suite semantically dense
enough that a backend which mis-implements D semantics cannot pass it.
It does **not** own the matrix — which backends participate in which
existing test blocks is being expanded per backend in parallel
(`SystemLinker` in `ai/plans/dmd-backend.md`; the VM backends in their
own promotion streams). Every test added here becomes an obligation
those streams inherit.

Today "green" does not imply semantic fidelity because the corpus has
holes: real D behaviours (string switch, operator overloading,
signed/unsigned conversion, integer wraparound, struct/null value
marshaling, …) are not tested against *any* backend.

Two failed approaches inform this plan. Line coverage of `Ctfe` was
tried as the test-idea generator and hit diminishing returns fast: the
uncovered remainder is dmd's diagnostic-formatting branches, and each
new test lit up one error string while proving no behaviour. More
fundamentally, coverage answers "did tests execute this line?" when the
question that matters is "**if this backend were wrong, would any test
notice?**" — and a hand-curated backlog of feature ideas (the second
attempt) is a fish, not a fishing rod: once consumed, the agent has no
method for finding the next gap.

So this plan is built around three *generative* mechanisms that tell an
agent what test to write next without anyone imagining it.

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

## Oracle

`SystemLinker` (compiled, linked, executed native D) is the single
behaviour oracle for every backend except `Ctfe`
(`ai/plans/single-oracle.md`). Its behaviour — including exact message
text — is definitive; a backend that disagrees with it is wrong. Current
fixtures pin compiled-D expectations directly. Introduce a shared computed
sentinel only when a concrete migrated fixture demonstrates that hand-pinned
expectations are insufficient.

`Ctfe` (`source/quickbite/backends/ctfe/dmd_ctfe.d`) is **not** an oracle.
It is a convenient real-D fixture source — a fixture written against it
passes by construction and becomes a cross-backend obligation when other
backends join its block — but where it diverges from `SystemLinker`, its
behaviour is *characterized*, not treated as truth: pin what `Ctfe`
actually does in a separate `Ctfe`-tagged test with a comment naming the
divergence (the known one: druntime's CTFE assert formatter emits
`<double not supported>` for float failure messages), and keep
`SystemLinker`'s behaviour as the statement of what is correct.

## The generative mechanisms

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
approval (the approval gate); write its block as
`static foreach (backend; Matrix!(...))`
(`tests/ut/backends/package.d`), which defaults to **every mature
backend** — `SystemLinker` at minimum (the oracle), plus `Ctfe` and the
VM backends where they agree; deleting an `Omit!(B, Because.unconfirmed)`
to promote a backend into an existing fixture is pre-approved. A backend
that *fails* the new fixture is the plan working as intended: a found
semantic divergence. Fix it if the fix is small (strict TDD — the
fixture is the failing test); otherwise omit that backend with
`Omit!(B, Because.…, "note")` naming the divergence so the omission is
visible, and record it for that backend's stream. If the behaviour is
genuinely unsupported by a backend's design, pin an explicit
unsupported-diagnostic expectation instead. Then `ninja bin/ut` and
`bin/ut --random`.

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

A mutant in backend X can only be killed by a test block whose
`AliasSeq` includes X. When a mutant survives because no block on that
code path runs X at all, that is a matrix gap, not a corpus gap —
record it and hand it to that backend's promotion stream instead of
writing a redundant fixture.

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
   "X evaluates to / converts to / is an error" about computation,
   verified against the `SystemLinker` oracle. Claims that need the
   runtime environment (libc/OS) belong in `rt/`; record any that no
   current backend can yet run in the checklist as deferred.
3. For each claim, grep the corpus (`tests/ut/backends/runner/`) for
   an existing test. Misses become proposed fixtures (approval gate,
   oracle-verified, every passing backend in the `AliasSeq`).
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
| needs the runtime environment (libc/OS) | `../rt/` (today only `cstdlib`) |
| struct/null value round-trip | REPL driver, `tests/ut/bin/repl.d` |

The fixture helper is `runBackendSourceFixtureTests!backend(q{...})`
(the fixture's own `unittest` asserts; failures surface through
`.shouldThrowWithMessage`), inside a
`static foreach (backend; AliasSeq!(...))` block named
`@("name." ~ backend.stringof)` and tagged `@Tags(backend.stringof)`.
Value round-trips that must marshal a whole struct or a `null` use the
REPL driver (`runReplLoop`).

### Fixture rules (non-negotiable, from `ai/mistakes.md` / AGENTS.md)

- **No constant folding.** Runtime-shaped operands only: mutable
  locals, helper-function returns, parameters. Never bare literals in
  the expression under test — dmd folds `1 + 2` before any backend
  runs. Pattern: `int one() { return 1; } … assert(one() + 41 == 42);`.
- **No variadic functions** as fixtures.
- **Omit empty parens**: `doStuff;`, including inside `q{...}`.
- **No host-test asserts inside `q{...}`** — the fixture's `unittest`
  does the asserting.
- **Float assertion-failure messages omit `Ctfe`**: `Matrix!(Omit!(Ctfe,
  Because.diverges, "<double not supported> quirk, see pin"))` plus a
  sibling `AliasSeq!(Ctfe)` block pinning the actual wording (the
  `<double not supported>` quirk above). Passing float asserts are fine.
- **Approval gate.** Show the exact fixture in a syntax-highlighted
  block and stop for approval before writing it. Adding a backend to
  an existing test block's `AliasSeq`, or deleting an
  `Omit!(B, Because.unconfirmed)` from a `Matrix!(...)` block, is the
  only pre-approved move.
- **Never weaken a test to make it pass.** If CTFE rejects something,
  convert to an unsupported-diagnostic test and keep the inner
  supported assertion.

## Out of scope (deliberately)

- **Matrix expansion of existing tests** — which backends join which
  existing blocks is per-backend parallel work (`SystemLinker`:
  `ai/plans/dmd-backend.md`; VM backends: their promotion streams).
  This plan only feeds those streams obligations.
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

At that point "passes the suite" means "agrees with compiled D
semantics across the real language surface, with a measured kill rate
behind it" — which is the confidence this plan exists to provide. The
remaining distance to full drop-in status is then exactly the matrix
work the per-backend streams own: every backend running every block.

## Appendix: starter backlog (hand-curated; consume, don't extend)

Known gaps found by inspection. Each `[ ]` is one slice; sketches are
starting points — confirm the exact expected value against the oracle
before writing. When this list is empty, new work comes from A1–A3
only.

### Tier 1 — most likely to expose a real backend bug

- [x] **String switch.** Entirely distinct lowering from int switch;
  absent. *Done: `switch.stringCases` (Ctfe, SystemLinker).*
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
- [x] **Default struct equality (field-wise `==`).** No struct `==`
  anywhere. *Done: `struct.defaultEqualityComparesFields` (Ctfe,
  SystemLinker).*
  ```d
  struct Point { int x; int y; }
  Point make(int seed) { Point p; p.x = seed; p.y = seed + 1; return p; }
  unittest {
      assert(make(3) == make(3));
      assert(make(3) != make(4));
  }
  ```
- [x] **Custom `opEquals`.** No operator overloads tested at all.
  *Done: `struct.customOpEquals` (Ctfe, SystemLinker).*
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
- [x] **Catch a derived exception by base type + read a subclass
  field.** *Done: `exception.catchByBaseReadsDerivedField` (Ctfe,
  SystemLinker).*
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
- [x] **Signed/unsigned comparison conversion.** `-1 < 0u` is *false*
  in D. *Done: `signedUnsignedComparisonIsUnsigned` (Ctfe, Interpreter,
  Bytecode, SystemLinker) — exposed a real IR divergence (signed-only
  i32 comparison), recorded in `ai/plans/ir.md`.*
  ```d
  int neg() { return -1; }
  uint zero() { return 0u; }
  unittest { assert(!(neg() < zero())); }
  ```
- [x] **Integer wraparound at type boundaries.** *Done:
  `wraparoundAtTypeBoundaries` (all five backends).*
  ```d
  int top() { return int.max; }
  uint bottom() { return 0u; }
  unittest {
      int a = top();   assert(a + 1 == int.min);
      uint b = bottom(); assert(b - 1 == uint.max);
  }
  ```

### Tier 2 — common semantics, clear gaps

- [x] **Negative modulo sign rule.** `-7 % 3 == -1` (sign follows the
  dividend). Corpus only has positive modulo. *Done:
  `int.moduloSignFollowsDividend` (Ctfe, Interpreter, SystemLinker) —
  Bytecode and IR report `%` as an unsupported expression.*
- [x] **`>>>` zero-fill vs `>>` sign-extend.** *Done:
  `int.unsignedRightShiftZeroFills` (Ctfe, SystemLinker) — the VM
  backends report shifts as unsupported expressions.*
  ```d
  int seed() { return -1; }
  unittest {
      int v = seed();
      assert((v >> 28) == -1);
      assert((v >>> 28) == 15);
  }
  ```
- [x] **`final switch` on an enum** (must cover all members). *Done:
  `switch.finalSwitchOnEnumCoversAllMembers` (Ctfe, SystemLinker).*
- [x] **`switch` case ranges** (`case 0: .. case 3:`) and multi-value
  cases. *Done: `switch.caseRangesAndMultiValueCases` (Ctfe,
  SystemLinker).*
- [x] **Default function arguments** (`int add(int a, int b = 10)`).
  *Done: `function.defaultArgumentFillsOmittedParameter` (all five
  backends).*
- [x] **Overload resolution by signature** (`kind(int)` vs
  `kind(double)`). *Done: `function.overloadResolutionBySignature`
  (Ctfe, Interpreter, Bytecode, SystemLinker) — IR's VM asserts on
  f32/f64/ptr values, so the double overload cannot run.*
- [x] **`foreach` with index** `(i, e)` over a runtime array. *Done:
  `foreach.arrayWithIndex` (Ctfe, Interpreter, SystemLinker).*
- [x] **`foreach_reverse` over a runtime int array** (covered today
  only for `dchar` over a string). *Done:
  `foreach.reverseIntArrayVisitsBackToFront` (Ctfe, SystemLinker) —
  the Interpreter hits the lowering's post-decrement as unsupported.*
- [x] **Nested struct field access** (`outer.inner.v`). *Done:
  `struct.fieldChainReadsInnerStructMember` (Ctfe, SystemLinker).*
- [x] **Runtime AA insertion / growth** (`m[k] = v` building the map,
  overwrite, `.length`). Corpus only tests literal AAs + lookup, plus
  AA `.dup`. *Done: `assocArray.insertionGrowsAndOverwrites` (Ctfe,
  SystemLinker) — the Interpreter cannot index-assign into a
  still-null AA, despite passing the literal-AA tests.*

### Tier 3 — fills out existing-but-thin areas

- [x] **More operator overloads**: `opCmp`, `opBinary`, `opIndex`,
  `opUnary`, `opAssign`. *Done: `struct.opCmpOrdersValues`,
  `struct.opBinaryAddsOperands`, `struct.opIndexSelectsElement`,
  `struct.opUnaryNegatesValue`, `struct.opAssignFromScalar` (Ctfe,
  SystemLinker) — the VM backends cannot run struct-typed values.*
- [x] **Exception extras**: rethrow, multiple typed `catch` clauses
  selecting by type, `Error` vs `Exception` distinction. *Done:
  `exception.rethrowPropagatesToOuterHandler`,
  `exception.multipleCatchClausesSelectByDynamicType`,
  `exception.errorIsNotCaughtByExceptionHandler` (Ctfe, SystemLinker)
  — the VM backends report TryCatch as unsupported. Note: D has no
  bare `throw;`; rethrow is `throw e;` with an explicit reference.*
- [x] **Integer edge cases needing oracle confirmation**:
  `int.min / -1`, `int.min % -1`. *Done: CTFE rejects both as
  `integer overflow`, pinned as diagnostic tests with inner supported
  assertions (`int.divisionOverflowAtIntMinIsRejected`,
  `int.moduloOverflowAtIntMinIsRejected`, Ctfe only) — at runtime the
  x86_64 idiv traps (SIGFPE), so no runtime backend can pin a value.*
- [x] **`^^` power operator** on integers. *Done:
  `int.powerOperatorRaisesRuntimeIntegers` (Ctfe, SystemLinker) — not
  folded with runtime-shaped operands; its druntime lowering defeats
  every VM backend.*
- [x] **`float`/`real` variants** of the math intrinsics tested only
  for `double`; passing forms only. *Done: sqrt/fabs/pow/isNaN/
  isInfinity/signbit × float/real in `math.d` (Ctfe, Interpreter,
  Bytecode, SystemLinker) — BytecodeNewCore has no float/real types
  and IR asserts on float/real intrinsic calls. The pow-float block
  also omits SystemLinker: `pow!(float, float)` template-instance
  ownership makes the link order-dependent (recorded in
  `ai/plans/dmd-backend.md`).*
- [x] **Array extras**: `.dup`/`.idup` of a dynamic array, `.ptr`,
  jagged multidimensional arrays. *Done:
  `dynamicArray.dupDetachesCopyFromOriginal`,
  `dynamicArray.idupFreezesIndependentCopy`,
  `dynamicArray.ptrPointsAtFirstElement` (Ctfe, Interpreter,
  SystemLinker) and `dynamicArray.jaggedRowsKeepIndependentLengths`
  (Ctfe, SystemLinker) — bytecode backends and IR fail on array
  literals, `.length`, pointer casts, or jagged element types.*

### Tier 4 — value marshaling round-trip (REPL-driven)

CTFE marshaling of **whole struct values and `null` results** is never
exercised: tests evaluate `.field` ints, never a struct or a `null`.
These need the REPL driver because only the eval path reaches
`structValue`, `isFunctionLikeType`, and `Value.null_` in
`dmd_ctfe.d`. Verify the exact rendered string against the oracle
before pinning it.

- [x] **Struct value result** — declare `struct Point { int x; int y;
  }`, runtime locals `a`, `b`, evaluate `Point(a, b)`. *Done:
  `repl.backend.structValueRendersTypeNameAndFields` (Ctfe,
  Interpreter) — Bytecode reports struct literals as an unsupported
  expression (likewise for every fixture below).*
- [x] **Array of structs** — `arrayValue` recursing into
  `structValue`. *Done: `repl.backend.arrayOfStructsRendersEachElement`
  (Ctfe, Interpreter).*
- [x] **Struct with a null function-pointer field** — pointer-to-
  function arm of `isFunctionLikeType` (field is skipped). *Done:
  `repl.backend.nullFunctionPointerFieldIsOmitted` (Ctfe) — the
  Interpreter keeps the null field (`Callbacks(7, null)`) instead of
  omitting it; recorded in `ai/plans/value.md`.*
- [x] **Struct with a null delegate field** — delegate arm. *Done:
  `repl.backend.nullDelegateFieldIsOmitted` (Ctfe) — same Interpreter
  divergence.*
- [x] **Struct with a null class/pointer field** — kept as
  `Value.null_`; the only path producing a `null` result. *Done:
  `repl.backend.nullClassFieldRendersAsNull` and
  `repl.backend.nullPointerFieldRendersAsNull` (Ctfe, Interpreter) —
  exposed a real bug: `isSyntheticThisField` used a D cast on the
  extern(C++) dmd AST (unchecked, always non-null), so *every*
  null-valued field was silently dropped. Fixed via
  `isThisDeclaration`; these fixtures are the exposing tests.*
- [x] **Nested struct with a synthetic `this` context field** —
  `isSyntheticThisField`. Confirm dmd actually synthesises it in the
  CTFE literal first. *Done:
  `repl.backend.nestedStructOmitsSyntheticContextField` (Ctfe,
  Interpreter) — dmd does synthesise a `void*` context element in the
  CTFE literal; verified skipped post-fix.*
- [x] **Assoc array with struct values** — `assocArrayValue` into
  `structValue`. *Done:
  `repl.backend.assocArrayWithStructValuesRendersEntries` (Ctfe,
  Interpreter).*

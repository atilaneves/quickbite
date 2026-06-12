# Value Representation

## Status

Decision 2026-06-12: this plan now records the *removal* of
`quickbite.lang.Value`, reversing the earlier direction (expanding it to
losslessly store any D runtime value — see git history for that version
of this file). The trigger: the bytecode rewrite removed `Value` from its
VM, prompting an audit of what still needs the struct. Answer: nothing
structural in production code. What can be deleted, should.

## Audit findings (June 2026)

- The REPL uses `Value`'s structure only for display/control decisions:
  void suppression (`== Value.void_`), `:t` cells
  (`Value.typeName(asCharArrayString)`), string quoting, and
  success/failure gating (the `Diagnostic` arm of `EvalResult`, not
  `Value`). No `Value` ever feeds a later evaluation — session state is
  replayed from source.
- `repl/main.d` consumes only `submitDisplay` (a string). Benchmarks
  compare `TestResult[]` (strings). `Runner` never touches `Value`.
- The execution cores already exclude it by design (`ai/plans/bytecode.md`
  "No universal runtime value type"; `ai/plans/ir.md`); the interpreter's
  internal use is first-generation scaffolding.
- The only remaining customers of the structure are ~110 structural test
  assertions and the planned native value transport — both addressed
  below.

## Approved decisions

1. `quickbite.lang.Value` leaves the `Evaluator` contract: `EvalResult`
   carries the rendered display `string` (or a `Diagnostic`). The struct
   is deleted entirely once no backend needs it internally.
2. Display stays type-revealing — the point of REPL output is to tell the
   user what type a value is (`3u`, quoted strings; plain `42` is
   ambiguous) — and must become injective per type: every rendering
   unambiguously identifies the static type. The spec was agreed on
   2026-06-12 — see "Display format spec" below; the formatter and the
   migrated tests are both downstream of it.
3. The canonical formatter's end state is an in-program prelude template,
   `string __quickbiteFormat(T)(T value)`, written once in ordinary D
   with `static if` introspection. The frontend synthesizes expression
   cells as `__quickbiteFormat(expr)`; semantic analysis — shared by all
   backends — instantiates the template against the real static type
   (the type is encoded in the AST), so type-directed dispatch is
   resolved before any backend runs and backends only execute code.
   Consistency across backends by construction; the native backend ships
   a plain `string` across the dlsym boundary. The TLV serialization of
   `Value` variants in earlier drafts of `ai/plans/repl.md` is dead.
4. Interim: the contract changes first. Host backends (CTFE, interpreter,
   bytecode, IR) keep their existing reify → `Value` → `toString` chains
   as *private* formatting scaffolding behind the string-returning
   interface, deleted per backend as each becomes able to execute the
   prelude formatter. That is expected to happen: the bytecode and IR
   cores are headed for full D, so the formatter is an early, demanding
   test program for them, not a new requirement. During the interim the
   formatter-wrapped synthesis applies only to views consumed by backends
   that can execute it (see the snapshot/delta views in
   `ai/plans/repl.md`).
5. REPL mechanics survive without `Value`: void suppression is decided at
   synthesis time (the frontend knows when `typeof(expr)` is `void`, and
   `Cell.Kind.noDisplay` already exists), `:t` already round-trips
   `.stringof` as a string, and string quoting moves into the formatter.
6. The native backend is the behaviour oracle in the absence of a formal,
   machine-verifiable language specification (it remains one option among
   many for benchmarking). CTFE keeps its oracle role for pure code per
   `ai/plans/repl.md`.

## Display format spec (agreed 2026-06-12)

Principle: rendering is injective per static type, up to the listed
exceptions. Conventions, in order:

1. D literal syntax where it exists: `42`, `42u`, `42L`, `42UL`, `3.8`,
   `3.8f`, `true`/`false`, `'a'`, `"text"`, `null`, `[1, 2]`,
   `[1:10, 2:20]`.
2. One trailing `: type` annotation where D has no literal form:
   `42: byte`, `42: short`, `42: ubyte`, `42: ushort`, `3.8: real`,
   `'a': wchar`, `'a': dchar`, `"wide": wstring`, `"wide": dstring`.
   (The scalar suffix/annotation convention was already pinned by
   `repl.backend.numericScalarDisplayUsesDLiteralSuffixes`,
   tests/ut/bin/repl.d; the rest extends it.)
3. Floating values always include a decimal point or exponent: `3.0`,
   `3.0f`, `3.0: real` — never a bare `3` that collides with `int`.
4. Default types render bare; aggregates of non-default types get a
   single trailing annotation: `[1, 2]` is `int[]`; otherwise
   `[1, 2]: long[]`, `[]: ubyte[]`, `[1:10]: short[int]`. Elements,
   struct fields, and AA keys/values render bare — the aggregate
   annotation carries the type.
5. Structs and enums are already injective via their rendered names
   (`Point(1, 2)`, `E.a`); unchanged.
6. Width is displayed for strings and characters; type qualifiers
   (`const`/`immutable`) and mutability are not.
7. `void` results display nothing (REPL suppression); functions,
   delegates, and other non-renderable values display
   `<undisplayable>`. Pointer display is unspecified until pointers
   become a displayable feature — spec it then.

Deltas from current behaviour (June 2026 audit):

- `char`/`wchar`/`dchar` scalars render bare and unquoted today (`a` —
  colliding with ints and each other); unpinned by tests, free to fix.
- Whole-number doubles render `3` today, colliding with `int 3`;
  unpinned at the `Value.toString` level (only `3.8` is pinned).
- Wide strings are normalized to plain `"..."` today, pinned
  deliberately by `displaysWideStringValues` and
  `displaysWideCharacterArrayValues` (tests/ut/bin/repl.d); the agreed
  spec changes those assertions to `"wide": wstring` etc. — the test
  changes still need the usual approval at implementation time.
- Aggregate annotation (rule 4) has no existing test exercising a
  non-default aggregate, and `Value.Array` does not store its element
  type. Implementing rule 4 in the interim `Value` scaffolding would
  mean adding type metadata to a struct slated for deletion — defer
  rule 4 to the prelude formatter (which knows the static type) unless
  a test forces it earlier.
- `bool`, `null`, and empty arrays conform today but are unpinned.

## Test strategy

Three layers replace structural `Value` assertions:

1. Differential tests against the native oracle: run the same cell on the
   oracle and on the backend under test, assert identical display
   strings. No hand-maintained expected values; enforces formatter
   consistency as a side effect. Slow (~43 ms per native call, see
   `ai/plans/dmd-backend.md`) — a matrix job, not the inner loop.
2. Hand-written text expectations for the fast hermetic suite:
   `tests/ut/backends/evaluator/eval.d` migrates mechanically from
   `.should == Value(3u)` to `.should == "3u"`. Lossless once the display
   format is injective per type (decision 2).
3. Behavioural probes for runtime semantics display cannot reveal:
   wrap-around, truncation, signed/unsigned comparison and division,
   float-width effects. These test execution, not formatting.

`tests/ut/backends/evaluator/value.d` (15 blocks testing `Value`'s own
equality and rendering) is deleted together with the struct. Do not
replace structural assertions with `typeof(expr).stringof` checks: those
are computed by the shared frontend and pass even when a backend widens a
value at runtime.

All test additions/changes require approval first (AGENTS.md).

## Out of scope

`quickbite.executor.Value` (the legacy executor type) is unaffected, as
before; it dies with the legacy executors.

## Guardrails

- The display format spec above is the contract: no formatter or
  test-migration work may diverge from it without updating it first.
- Do not use string heuristics in REPL/frontend code to classify D
  source.
- Do not use failed evaluation as REPL control flow.
- Keep backend-specific DMD conversion inside backend adapters while the
  interim scaffolding lives.

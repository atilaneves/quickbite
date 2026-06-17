# Value Representation

## Status

Decision 2026-06-12: this plan now records the *removal* of
`quickbite.lang.Value`, reversing the earlier direction (expanding it to
losslessly store any D runtime value — see git history for that version
of this file). The trigger: the bytecode rewrite removed `Value` from its
VM, prompting an audit of what still needs the struct. Answer: nothing
structural in production code. What can be deleted, should.

Decision 2026-06-13: the display principle is reversed from "injective per
static type" to "round-trips as valid D". REPL output must be parseable D
that evaluates back to the value; it is no longer the channel for telling
the user a value's type. Type queries move to `typeof`/`it.typeof`
(`ai/plans/repl.md`). This drops the invented `: type` annotations the
2026-06-12 spec introduced; see the rewritten "Display format spec" and
"Test strategy" below. `EvalResult` stays a display `string` or a
`Diagnostic` — carrying a separate static type alongside it was considered
and rejected this session: the type is resolved by semantic analysis
(including `auto`-deduced return types) before any backend runs and is
identical across backends, so it belongs to the frontend, not the eval
result. A backend cannot produce a different *type* for an expression,
only different runtime *bits* — which the value digits and behavioural
probes catch (see "Test strategy").

Decision 2026-06-13 (implemented): the `EvalResult` contract now carries
the rendered display `string` (or a `Diagnostic`), completing decision 1.
`EvalResult._payload` is `SumType!(string, Diagnostic)`; `value()` is
replaced by `display()`. The `Value -> display-string` rendering moved to
the per-backend `eval(FuncDeclaration)` boundary via a single shared helper
`displayString(Value, FuncDeclaration)` in
`source/quickbite/backends/evaluator.d`, so every backend and the
`eval(Cell)`/`eval(string)` paths render identically: `void` -> `""`, a
character-array return -> the quoted string with its width suffix,
everything else -> `Value.toString`. Per decision 4 this is interim: each
backend keeps its private reify -> `Value` -> `toString` scaffolding behind
the string-returning interface, to be deleted per backend as it learns to
execute the prelude formatter. `Value`, `value.d`, `asCharArrayString`,
`stringTypeAnnotation` and `dText` are unchanged. The REPL
(`source/quickbite/repl.d`) keeps the synthetic-name scrubbing
(`userDiagnostic`/`userValueString`), now applied to the display string
carried by `EvalResult`; `Repl.submit` returns the display `string`.

Decision 2026-06-17: the endgame is narrowed from "delete the struct
entirely" to "remove the *shared, cross-backend* value type". The
tree-walking interpreter's *internal* runtime representation is
legitimately a boxed tagged union: that is the natural form for a
recursive AST walker, and re-expressing structs/classes/closures as raw
bytes would duplicate the bytecode VM's hardest work inside the backend
whose whole value is simplicity. So decisions 1-5 stand for the
`Evaluator` contract and the display path — the reify → `Value` →
`toString` scaffolding still goes, replaced by the decision-3 prelude
formatter — but the interpreter keeps a boxed value type for its own
evaluation. The change is one of *ownership*: that type becomes
interpreter-package-private (under `backends/interpreter/`) rather than
the shared `quickbite.lang.Value` that other backends and `EvalResult`
no longer touch. The bytecode and IR cores stay native-layout and never
reintroduce a boxed value (their cores already exclude it by design;
`ai/plans/bytecode.md` "No universal runtime value type"). This narrows
the deletion target only — both backends have identical DMD type info,
so this is not about capability. If the tree-walking interpreter is
itself later retired in favour of the VM, its private boxed type dies
with it, but that is a separate decision not taken here.

## Audit findings (June 2026)

- At audit time the REPL used `Value`'s structure only for
  display/control decisions: void suppression (`== Value.void_`), `:t`
  cells (`Value.typeName(asCharArrayString)`), string quoting, and
  success/failure gating (the `Diagnostic` arm of `EvalResult`, not
  `Value`). No `Value` ever feeds a later evaluation — session state is
  replayed from source. Since implemented away on this branch: void
  suppression is now an empty-display-string check and `:t` is
  frontend-answered (see decision 5 Progress and the Status "implemented"
  paragraph).
- `repl/main.d` consumes only `submitDisplay` (a string). Benchmarks
  compare `TestResult[]` (strings). `Runner` never touches `Value`.
- The execution cores already exclude it by design (`ai/plans/bytecode.md`
  "No universal runtime value type"; `ai/plans/ir.md`); the interpreter's
  internal use is first-generation scaffolding.
- The remaining customers of the structure (post-implementation): the
  EvalResult-contract assertions in `eval.d`/`repl.d` have been migrated
  to display strings, so what is left is
  `tests/ut/backends/evaluator/value.d` (`Value`'s own equality/rendering)
  plus the interpreter's internal `Value`-based execution scaffolding —
  both addressed below.

## Approved decisions

1. `quickbite.lang.Value` leaves the `Evaluator` contract: `EvalResult`
   carries the rendered display `string` (or a `Diagnostic`). The struct
   is deleted entirely once no backend needs it internally.

   Done 2026-06-13: the contract flip is implemented; see the Status
   "implemented" paragraph. The struct itself is NOT yet deleted — it
   survives as private per-backend scaffolding per decision 4.
2. Display round-trips as valid D: every rendering is a D expression that
   parses and evaluates to a value equal to the original (Python's `repr`
   principle). It is *not* the channel for revealing a value's static
   type. Where D has no literal form for a type, the rendering's static
   type widens on re-parse (the *value* round-trips, the type does not)
   and the user reaches for `typeof`/`it.typeof` instead. The spec was
   reversed on 2026-06-13 (it required injectivity per type on
   2026-06-12); see "Display format spec" below. The change is small in
   practice: the literal-suffix renderings (`3u`, `42L`, `3.0f`, `3.0L`,
   `"x"w`) already round-trip *and* reveal type; only the invented
   `: type` annotations (former rules 2 and 4) are dropped. The formatter
   and the migrated tests are both downstream of it.
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
   Type disambiguation of display output is now an explicit user action —
   `typeof`/`it.typeof` (`ai/plans/repl.md`) — since display no longer
   encodes type for no-literal types (decision 2); `:t` stays
   frontend-answered for latency, not routed through a backend.

   Progress 2026-06-13: `:t`/type-expression cells are now actually
   frontend-answered. `EvalSession.typeExpressionName` resolves the type
   from the DMD AST (the alias-probe type's `Type.toChars`, which DMD also
   uses to compute a type's `.stringof`, so the rendering is byte-for-byte
   identical) and `ReplSession.submit` records it on the `ReplCell`. The
   REPL short-circuits these cells, displaying the name bare without
   calling `backend.eval`, `Value.asCharArrayString`, or `Value.typeName`.
   The old `.stringof`-via-backend path remains only as a fallback for
   inputs the frontend cannot resolve.
6. The native backend (`SystemLinker`) is the single behaviour oracle in the
   absence of a formal, machine-verifiable language specification (it remains
   one option among many for benchmarking). CTFE is not an oracle; where it
   diverges, its behaviour is characterized, not treated as truth
   (`ai/plans/single-oracle.md`).

## Display format spec (agreed 2026-06-12; principle reversed 2026-06-13)

Principle: every rendering is valid D that parses and evaluates to a value
equal to the original (round-trip / Python-`repr`). Rendering is *not*
required to be injective per type — where D has no literal form for a type,
the rendering's static type widens on re-parse (the value round-trips, the
type does not) and `typeof`/`it.typeof` disambiguates. Conventions, in
order:

1. D literal (or literal-like) syntax where it exists, round-tripping both
   value and type: `42`, `42u`, `42L`, `42UL`, `3.0`, `3.0f`, `3.0L`
   (real — the `L` float suffix round-trips), `true`/`false`, `'a'`,
   `"text"`, `"text"w` (wstring), `"text"d` (dstring), `null`, `[1, 2]`,
   `[1:10, 2:20]`. The suffix convention was already pinned by
   `repl.backend.numericScalarDisplayUsesDLiteralSuffixes`,
   tests/ut/bin/repl.d.
2. Types with no D literal form render in their natural bare/literal form,
   accepting that the static type widens on re-parse:
   - `byte`/`ubyte`/`short`/`ushort` → `42` (re-parses as `int`).
   - `char`/`wchar`/`dchar` → `'a'` (re-parses as `char`).
   `typeof`/`it.typeof` disambiguates. The former `: type` annotations
   (`42: byte`, `'a': wchar`) are dropped — they are not parseable D. (A
   round-tripping `cast(wchar)'a'` form is available if exact-type
   round-trip is later wanted, but bare + `typeof` is the default.)
3. Floating values always include a decimal point or exponent: `3.0`,
   `3.0f`, `3.0L` — never a bare `3` that re-parses as `int`. (Now a
   round-trip requirement, not an injectivity one.)
4. Aggregates round-trip element-wise: each element/key/value renders in
   its own round-tripping form, so the aggregate self-identifies without
   an annotation. `[1, 2]` is `int[]`; `[1L, 2L]` is `long[]`; `[1:10]`
   is `int[int]`. Aggregates whose element type has no literal form stay
   ambiguous (`[1, 2]` could be `ubyte[]`) — `typeof` disambiguates, same
   as the scalar case. The former trailing `: long[]` annotation is gone,
   and with it the need for element-type metadata on `Value.Array`.
5. Structs and enums round-trip via their rendered names (`Point(1, 2)`,
   `E.a`); unchanged.
6. Width round-trips for strings via the literal suffix (`"x"w`, `"x"d`);
   for characters it does not (all widths render `'a'`, disambiguated by
   `typeof`). Type qualifiers (`const`/`immutable`) and mutability are not
   displayed.
7. `void` results display nothing (REPL suppression). Functions,
   delegates, pointers, and other values with no D expression form cannot
   round-trip; there is no contract to honour, so render whatever is most
   useful to the reader (e.g. `<function int(int)>`, `&name`) — optimise
   for convenience, not parseability. Pointer display is otherwise
   unspecified until pointers become a displayable feature — spec it then.

Deltas from current behaviour (June 2026 audit):

- `char`/`wchar`/`dchar` scalars render bare and unquoted today (`a` —
  colliding with ints and each other); unpinned by tests, free to fix.
  Target: `'a'` for all three (the wide ones re-parse as `char`; `typeof`
  disambiguates).
- Whole-number doubles render `3` today, colliding with `int 3`;
  unpinned at the `Value.toString` level (only `3.8` is pinned). Target:
  `3.0`.
- Wide strings are normalized to plain `"..."` today, pinned
  deliberately by `displaysWideStringValues` and
  `displaysWideCharacterArrayValues` (tests/ut/bin/repl.d); the
  round-trip spec changes those assertions to `"wide"w`/`"wide"d` (the
  literal suffix, not the dropped `: wstring` annotation) — the test
  changes still need the usual approval at implementation time.
- Aggregates of non-default element type need no annotation under the
  round-trip spec: the elements carry their own suffixes (`[1L, 2L]`), so
  the aggregate self-identifies and `Value.Array` needs no element-type
  metadata. The former rule 4 (a trailing `: long[]` annotation) is gone;
  nothing to defer. Aggregates whose element type has no literal form
  (`ubyte[]`) stay ambiguous by design — `typeof` disambiguates.
- `bool`, `null`, and empty arrays conform today but are unpinned.
- The Interpreter keeps null function-pointer/delegate struct fields
  that the CTFE marshaling omits (`Callbacks(7, null)` vs
  `Callbacks(7)`); found by the Tier 4 coverage fixtures
  (`repl.backend.nullFunctionPointerFieldIsOmitted` /
  `nullDelegateFieldIsOmitted`, Ctfe-only pending resolution). The
  prelude formatter makes the policy question moot — one formatter,
  one rendering — but the interim scaffolding diverges today.

## Test strategy

Three layers replace structural `Value` assertions:

1. Differential tests against the native oracle: run the same cell on the
   oracle and on the backend under test, assert identical display
   strings. No hand-maintained expected values; enforces formatter
   consistency as a side effect. Slow (~43 ms per native call, see
   `ai/plans/dmd-backend.md`) — a matrix job, not the inner loop.
2. Hand-written text expectations for the fast hermetic suite:
   `tests/ut/backends/evaluator/eval.d` has migrated (done 2026-06-13)
   from `.should == Value(3u)` to `.should == "3u"`;
   `tests/ut/backends/evaluator/value.d` is still present, to be deleted
   with the struct. One display string now
   carries two distinct assertions, and the migration must keep them
   straight:
   - The **suffix** witnesses the **static type** — but only where D has a
     literal form (`3u`, `42L`, `3.0f`, `'a'`, `"x"w`). That is a frontend
     fact, identical on every backend, so a suffix assertion pins semantic
     analysis, not backend behaviour. Types with no literal form (`byte`,
     `wchar`) carry no suffix and cannot be pinned this way — by design;
     the round-trip spec dropped the annotations that used to.
   - The **value digits** witness the **backend's runtime behaviour**.
     Narrowing/widening/signedness are caught here, not by the suffix, by
     constructing expressions where the bug changes observable digits:
     drive the static type with an explicit `cast` so the formatter
     renders at the narrow type, and pick operands where truncation,
     wrap-around, or sign flips the result — e.g.
     `cast(ubyte)(255 + 1)` → `"0"`, `cast(byte)(byte.max + 1)` →
     `"-128"`, `-1 / 2u` → `"2147483647u"`, `-8 >> 1` → `"-4"`.
   The migration is no longer "lossless because injective per type" (the
   2026-06-12 framing): a bare `42` no longer pins `int` vs `byte`. Where a
   test must pin a no-literal subtype, it asserts a value-observable
   behaviour (this layer) or queries `typeof` (a frontend fact), not the
   bare display.
3. Behavioural probes for runtime semantics display cannot reveal:
   wrap-around, truncation, signed/unsigned comparison and division,
   float-width effects. These test execution, not formatting — and, per
   layer 2, they are the *only* layer that exercises a backend's runtime
   type handling. The boundary: a width/storage difference that never
   changes an observable value is untestable through the string, but also
   unobservable to any program — not a bug that can matter.

`tests/ut/backends/evaluator/value.d` (15 blocks testing `Value`'s own
equality and rendering) is deleted together with the struct. Do not pin a
backend's runtime type via `typeof(expr).stringof` or any static-type
channel: those are computed by the shared frontend and pass even when a
backend widens a value at runtime — that is what layer 2's digit
assertions and layer 3 are for.

All test additions/changes require approval first (AGENTS.md).

## Remaining work

The contract flip (decision 1) and frontend-answered `:t` (decision 5)
are done; what is still pending, in order:

1. Build the prelude formatter `string __quickbiteFormat(T)(T value)`
   (decision 3) so backends render by executing D rather than via the
   interim `displayString`/`Value.toString` scaffolding.
2. Delete the private reify → `Value` → `toString` scaffolding per
   backend (decision 4) as each gains the formatter.
3. Remove the *shared* `quickbite.lang.Value` (decision 2026-06-17):
   once no backend depends on it as a cross-backend type, relocate the
   tree-walking interpreter's internal boxed representation to an
   interpreter-package-private type, then delete the shared struct and
   `tests/ut/backends/evaluator/value.d` together. The interpreter keeps
   a boxed value internally; only the shared type is deleted.

## Out of scope

`quickbite.executor.Value` (the legacy executor type) is unaffected, as
before; it dies with the legacy executors.

## Guardrails

- The display format spec above is the contract: no formatter or
  test-migration work may diverge from it without updating it first.
- Display renderings must round-trip as valid D (decision 2): a rendering
  that cannot be parsed back and evaluated to an equal value is a spec
  violation, except for the no-D-expression values of rule 7.
- Do not use string heuristics in REPL/frontend code to classify D
  source.
- Do not use failed evaluation as REPL control flow.
- Keep backend-specific DMD conversion inside backend adapters while the
  interim scaffolding lives.

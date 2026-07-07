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
with it, but that is a separate decision not taken here. (Superseded in
part by 2026-06-23: the "boxed tagged union is the natural form" claim is
downgraded from a settled decision to the *current implementation* of one
seam endpoint — see below.)

Decision 2026-06-23: this plan is now the **Track B charter** — the
interpreter's value representation — companion to the FFI bridge plan
(`ai/plans/ffi.md` §5/§6). The two are worked in parallel and meet only at
the FFI seam.

- The seam (`ffi.md` §5) is `materialize(value, Type) -> ABI bytes` and
  `reify(Type, ABI bytes) -> value`. The interpreter **owns its
  materialize/reify implementation**; the FFI bridge core never sees `Value`.
  Today that implementation is the boxed-aggregate marshalling currently in
  `backends/ffi.d` (`marshalArgument`/`unmarshalValue`), which moves to the
  interpreter side of the seam. The `ffi.md` §34.3 "Track B" / `B*` ladder
  rungs (typed slices, struct returns, nested slices, mutable-slice and
  receiver writeback) are this plan's, not the bridge's.
- The 2026-06-17 reasoning ("re-expressing aggregates as raw bytes duplicates
  the VM's hardest work") is reconsidered: it argues against *reimplementing*
  layout, not against *reusing* it. It is **recursive aggregate boxing**
  (`Struct = Value[] fields`, `Array = Value[] elements`) — not boxing per
  se — that forces per-call marshalling. Holding FFI-crossing aggregates in
  native layout *behind the handle* (reusing DMD offsets) would collapse the
  `B*` rungs; whether to do so is an **open empirical question**, not a
  settled decision.
- Why empirical: the point of multiple backends is to try representations and
  measure which is fastest (the project goal is latency). We do not yet know
  whether boxed `Value` or native-layout aggregates is faster in the
  interpreter — and we **cannot measure until FFI works**, because measuring
  means running real dub projects' unittests, which need the bridge. So the
  ordering is: carve the seam, keep the boxed `materialize` working so FFI and
  real tests run, *then* try native-layout aggregates behind the same
  interface and measure. Do not climb the `B*` rungs as ever-more boxed
  marshalling on the assumption boxing stays.
- Native layout in the interpreter is **not** a compile step and does not cost
  emit latency. Representation (boxed vs native) and execution strategy (walk
  the AST vs lower to bytecode) are orthogonal: the no-emit advantage is the
  *tree-walker vs VM* axis and survives either representation. A native-layout
  interpreter still walks the AST; it only reads/writes native frame memory at
  DMD offsets instead of boxed `Value`s. So the experiment compares two
  *no-emit* interpreters, not interpreter-vs-VM.
- What to measure, then, are the real run-time cost axes (none is compile):
  boxing's per-aggregate GC allocation + tag dispatch + per-crossing FFI
  marshalling, *versus* native layout's GC-root bookkeeping
  (`addRange`/`removeRange`, conservative frame scanning) + runtime
  type-metadata synthesis for druntime leaves (`bytecode.md`). Plus the
  correctness ceiling boxing cannot pass at any speed (`&local`, unions,
  reinterpret casts, slices into locals) — which may decide the question
  independent of latency.
- `Value` is a Lox-derived tagged union (Crafting Interpreters). It exists to
  carry a runtime type tag that a *dynamically typed* interpreter needs;
  Quickbite's DMD frontend stamps a static `Type` on every node, so the tag
  is redundant. The box's only remaining benefit is host-language
  convenience (a uniform D type to return from `eval(Expr)`); that benefit is
  what is paid back at the seam.

Decision 2026-06-23 (research validation + reframe): a cross-language survey
(LuaJIT, CPython, Ruby MRI, the JVM, .NET, Go; plus the static-language
interpreters OCaml/GHCi/JVM/MLton and the CTFE engines of Clang/D/Zig) settles
two things bearing on the open question above.

- The boxed-leaves + native-layout-aggregates-behind-a-handle shape is the
  **universal** answer, not a Quickbite invention. Every boxed-value runtime that
  does FFI well keeps its box for scalars / host convenience but holds
  FFI-crossing aggregates in native ABI layout behind a thin handle, never as a
  recursive tree of boxed values: CPython `ctypes`/`cffi` `cdata`, Ruby
  `Fiddle::Pointer` / `FFI::AbstractMemory`, LuaJIT `GCcdata`, the JVM's
  `MemorySegment`+`VarHandle` (Panama) versus boxed-object JNI, and .NET
  *blittable* types (identical bit layout → pinned, not marshalled). The handle
  and the native-layout representation are the **same idea at two transparency
  settings** — opaque (never read through the pointer; the `ffi.md` §11.3 escape
  hatch) versus transparent (read/write fields at DMD offsets; the native-layout
  interpreter). The boxed interpreter sits between them, paying a per-crossing
  materialize/reify.
- The reframe: moving aggregates to native layout is a **correctness win first,
  latency second** — which dissolves the "worse interpreter to save FFI work"
  framing. The static-language survey confirms the Lox type *tag* is redundant
  for type-safety (the JVM operand stack carries none; MLton is fully unboxed;
  OCaml's tag exists for the GC and separate-compilation polymorphism, not
  types). But runtime discriminants are still required for GC pointer-tracing and
  for sum-type/union/variant dispatch — exactly the correctness ceiling
  (`&local`, unions, reinterpret casts, slices into locals) that *recursive
  aggregate boxing* cannot pass at any speed. Native layout passes it by
  construction. This is the decider already named in the 2026-06-23 measured
  result below; the survey corroborates it.
- Latency caveat, to keep expectations honest: native layout removes
  per-aggregate marshalling + GC alloc + tag dispatch (the measured ~26x), but
  **not** the libffi `ffi_call` dispatch cost — only a JIT erases that, which a
  tree-walker does not have. So native layout makes interpreter FFI *correct and
  marshalling-free*, not *fast in absolute terms*; the interpreter's edge stays
  no-emit (the orthogonality argument above), not fast calls.
- `std.variant.Variant` considered and rejected as a replacement for the current
  `SumType` `Value`. It is a heavier box for the same strategy, not a different
  strategy: it still recursively boxes aggregates (a *guest* `struct Point` is a
  DMD AST type, not a host D type, so it cannot be stored in a `Variant` at its
  native type — it becomes `Variant[]`, exactly as it is `Value[]` today), it
  reintroduces the runtime `TypeInfo` dispatch the static frontend makes
  redundant, it heap-allocates past its inline buffer, and it drops `match`
  exhaustiveness. It moves the representation the wrong way along the axis above
  (toward a worse box); the fix moves the other way (toward native bytes behind a
  handle).

Progress 2026-06-19: the prelude formatter now owns the scalar literal
suffix cases that were previously only pinned through `Value.toString`:
`uint`, `long`, `ulong`, `float`, and `real` render as D literals with
`u`, `L`, `UL`, `f`, and `L` suffixes respectively, and the whole-floating
decimal-point rule is shared across `float`, `double`, and `real`. This is
still a prelude-surface slice only: expression cells are not yet synthesized
as `__quickbiteFormat(expr)`, and the interim backend `Value` rendering
path remains in place.

Progress 2026-06-19: the prelude formatter now owns the character-width and
string-width display rules: `char`/`wchar`/`dchar` render as character
literals, and `wstring`/`dstring` render as string literals with `w`/`d`
suffixes. This is still a prelude-surface slice only; the interim backend
`Value` rendering path remains in place.

Progress 2026-06-19: the prelude formatter now owns array element rendering
for dynamic and static arrays, so aggregate elements carry their own literal
suffixes (`[1u, 2u]`, `[1L, 2L]`, `["a"w, "b"w`) instead of relying on
`std.conv.text`'s widened element rendering. This is still a prelude-surface
slice only; expression cells are not yet synthesized as
`__quickbiteFormat(expr)`.

Progress 2026-07-06: the prelude formatter now owns struct, enum, and
associative-array rendering, closing the `text(value)` catch-all for the
aggregate cases: enums render as qualified members (`E.b` — diverging
from the interim `Value` path's bare member name, which is not
round-trippable D), structs render `Name(field, ...)` with each field in
its own round-tripping form (`Point(1, 2L)`, quoted string fields), and
AAs render `[key:value]` with element-wise literal suffixes. Multi-entry
AA rendering order is left unpinned (D AA iteration order is
unspecified; round-trip validity does not depend on it). Non-member enum
values (`cast(E)5`) are also unpinned. This completes the formatter half
of remaining-work item 1; the wiring half is untouched and every REPL
display still runs through the interim `displayString`/`Value.toString`
scaffolding.

Progress 2026-07-06: selected expression cells now synthesize
`__quickbiteFormat(expr)` instead of displaying the backend `Value`
directly. `Ctfe` and `Interpreter` opt in through a backend capability; the
frontend imports `quickbite.repl_prelude`, rewrites struct expression cells
that need 64-bit integer suffixes, and unwraps the formatter's returned string
at the evaluator boundary. The gate is intentionally narrow so existing range,
delegate, null-field, function-diagnostic, enum, and scalar displays keep their
current contracts while the `long`/`ulong` struct-field fallback moves out of
`Value.toString`.

Progress 2026-07-06: the formatter gate now covers struct expression cells
with function-pointer and delegate fields, so CTFE and Interpreter render null
callable fields through the prelude instead of diverging through the interim
`Value.toString` scaffolding (`Callbacks(7, null)`, `Handler(9, null)`). The
prelude has a callable branch that renders null function pointers and delegates
as `null`; the Interpreter preserves null through pointer/delegate casts needed
by DMD's lowering.

Progress 2026-07-06: the formatter gate now also covers struct expression
cells with class-reference fields, moving null class fields (`Node(5, null)`)
onto the prelude path for CTFE and Interpreter. The display text is unchanged;
the frontend now proves these expressions synthesize `__quickbiteFormat(expr)`
instead of falling back to the interim `Value.toString` scaffolding.

Progress 2026-07-06: the formatter gate now covers struct expression cells
with `long[]`/`ulong[]` fields, moving array element suffix rendering
(`Bag([1L, 2L])`) onto the prelude path for CTFE and Interpreter. The gate is
still narrower than all array fields: Phobos range structs with plain `int[]`
state keep the existing `Value.toString` display contract until range displays
are deliberately moved.

Progress 2026-07-06: the formatter gate now covers struct expression cells
with enum fields and enum-array fields. These need the prelude because enum
members render as qualified D expressions there (`Box(E.b)`,
`Box([E.a, E.b])`), unlike the interim `Value.toString` scaffolding's bare
member names.

Progress 2026-07-07: the formatter gate now covers struct expression cells
with character-array fields (`string`/`wstring`/`dstring`) and associative
array fields. CTFE and Interpreter therefore render string-width suffixes and
AA element suffixes through the prelude path (`Person("Bob", "wide"w)`,
`Lookup(["answer":42L])`) instead of relying on the interim
`Value.toString` scaffolding.

Progress 2026-07-07: the formatter gate now covers struct expression cells
with ordinary pointer fields. Null pointer fields (`Link(4, null)`) therefore
use the prelude path for CTFE and Interpreter, matching the existing callable,
delegate, and class-reference null-field cases without relying on the interim
`Value.toString` scaffolding.

Progress 2026-07-07: the formatter gate now covers direct expression cells
whose return type is an enum, selected dynamic/static arrays, or an
associative array. Direct enum expressions and enum arrays therefore use the
prelude's qualified member rendering (`E.b`, `[E.a, E.b]`), and direct
suffix-sensitive arrays/AAs use element-wise literal rendering (`[1L, 2L]`,
`["answer":42L]`) instead of the interim `Value.toString` scaffolding. The
prelude enum formatter now returns named members through generated literal
strings so the Interpreter can execute the direct enum path without falling
through `std.conv.text`'s enum formatting.

Decision 2026-07-07: ownership split with the bytecode rewrite
(`ai/plans/bytecode.md`), so the two tracks can run in parallel without one
building what the other deletes.

- This plan's formatter track owns the frontend gate (`frontend/cell.d`),
  the prelude (`source/quickbite/repl_prelude.d`), and the opted-in
  backends (`Ctfe`, `Interpreter`) including their interim-scaffolding
  deletion. It does not touch `backends/bytecode/**`.
- The bytecode backends opt in through their own plan's slice 11 ("Prelude
  formatter execution", `bytecode.md`): the new core earns display by
  executing `__quickbiteFormat`, then deletes its display scaffolding (the
  deletion inventory in `bytecode.md`). Until then, `repl.d` display-string
  tests are frozen for `Bytecode`/`BytecodeNewCore`.
- Matrix rule: new or changed display tests are parameterized over
  formatter-capable backends only (today `Ctfe`, `Interpreter`);
  `Bytecode`/`BytecodeNewCore` join a display test's `AliasSeq` when they
  opt in. If a formatter change alters an expected display string that an
  existing test row pins on a bytecode engine through the interim
  `Value.toString` path, drop that engine from the block's `AliasSeq` and
  record it as a pending slice-11 re-earn — do not implement matching
  `Value` scaffolding on the bytecode side. (This is the existing
  omit-don't-pin fixture convention applied to display rows.)

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
- Wide strings: done — `displaysWideStringValues` and
  `displaysWideCharacterArrayValues` (tests/ut/bin/repl.d) now assert
  `"wide"w`/`"wide"d` per the round-trip spec (approved and green). Note
  they pass today via the interim `Value.toString` path
  (`stringTypeAnnotation`), not the prelude formatter — see remaining-work
  item 1.
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

1. Complete the prelude formatter `string __quickbiteFormat(T)(T value)`
   (decision 3): the formatter surface is done as of 2026-07-06 — structs,
   enums, and AAs now render per the round-trip spec (see Progress above)
   and the `text(value)` catch-all covers only the rule-7 no-contract
   values. What remains is completing the incremental wiring: expression
   cells are now synthesized as `__quickbiteFormat(expr)` for selected
   return types when the backend opts into the prelude formatter, but many
   expression displays still run through the interim
   `displayString`/`Value.toString` scaffolding. Keep expanding the gate per
   backend (decision 4: only views consumed by backends that can execute it)
   until the display spec is no longer enforced by the path scheduled for
   deletion. Items 2 and 3 below are blocked until this wiring lands.
2. Delete the private reify → `Value` → `toString` scaffolding per
   backend (decision 4) as each gains the formatter.
3. Remove the *shared* `quickbite.lang.Value` (decision 2026-06-17):
   once no backend depends on it as a cross-backend type, relocate the
   tree-walking interpreter's internal boxed representation to an
   interpreter-package-private type, then delete the shared struct and
   `tests/ut/backends/evaluator/value.d` together. Only the shared type is
   deleted; the interpreter keeps an internal value type whose *shape* is the
   2026-06-23 open question.

Track B (FFI seam) work, parallel to the bridge track in `ffi.md` §6:

4. Carve the seam: move the boxed `Value <-> ABI bytes` marshalling out of the
   FFI core (`backends/ffi.d`) and into the interpreter as its
   `materialize`/`reify` implementation, behind the `ffi.md` §5 interface.
   Mechanical and behaviour-preserving — the existing `rt/` FFI suite stays
   green. This is the prerequisite that unblocks the two parallel tracks.
5. Own the `ffi.md` §34.3 `B*` rungs (boxed-slice/struct/nested/writeback
   marshalling) as the interpreter's `materialize`/`reify`, keeping FFI working
   so real dub tests can run.
6. Experiment (do not pre-commit): hold FFI-crossing aggregates in native
   layout behind the handle (reuse DMD offsets), measure latency against the
   boxed implementation across the benchmark suite, and keep whichever wins.
   Several `B*` rungs collapse to the identity under native layout.

   Result 2026-06-23 (measured): a *bolt-on* native-layout `NativeMarshaller`
   is the wrong unit of change — keep the boxed marshaller for now. Evidence:
   - The benchmark suite never crosses the FFI seam: `bin/bench`'s fixtures
     (`tests/example.d`, dub projects) have no native dependency, so the
     interpreter row is frontend + tree-walking with zero marshalling. A
     marshaller swap is invisible to `ci.sh`/`bin/bench`; only the `rt/`
     dependency-image suite exercises the seam.
   - The representation gap is real but lives off the seam. Construct +
     read-back micro-benchmark (1M iters): a boxed 4-long struct is ~26x a
     native byte layout (1049 ns vs 40 ns); a boxed 16-long slice ~27x
     (2220 ns vs 81 ns) — i.e. boxing's GC alloc + `SumType` tag dispatch.
   - A native-layout marshaller cannot capture that gap while the interpreter
     stays boxed: its inputs are already-boxed `Value`s and its output must be
     a boxed `Value`, so it boxes on the way in and out regardless and only
     adds blob bookkeeping. The 26x is realizable only when aggregates are
     never boxed — the interpreter-wide native representation (decision 2026-
     06-23, remaining-work item 3), where the seam collapses to identity.
   - The decider is the correctness ceiling (`&local`, unions, reinterpret
     casts, slices into locals), not latency; it lands with the
     representation change, not a marshaller swap.

   Conclusion: defer native layout to the interpreter-representation track and
   measure it on the tree-walker hot path, not the FFI seam. The `B*` rungs
   (§34.9/§34.10/§34.11) are landed as boxed marshalling, which is correct and
   keeps real dub tests runnable in the meantime.

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
- Formatter-track changes must not touch `backends/bytecode/**`; bytecode
  display parity goes through `bytecode.md` slice 11 (decision 2026-07-07).
  When a display change collides with a bytecode-pinned row, apply the
  matrix rule (drop the engine from that block, record the pending re-earn)
  rather than extending bytecode display scaffolding.

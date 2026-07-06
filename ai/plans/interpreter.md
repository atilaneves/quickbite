# Design: Interpreter — executing real project source

This is the **Interpreter language-completeness plan**. Its terminal goal: the
`Interpreter` backend executes the project source of a real dub package — every
statement and expression DMD hands it — so the package's unittests run under the
interpreter and agree, byte for byte, with the `SystemLinker` oracle. It is the
prerequisite no other plan owns.

**Why this plan exists.** `ai/plans/ffi.md` (§34) declared the FFI ladder done,
with the one-sentence terminal goal (§34.1): "*a backend executes project source
while every compiled dependency leaf is called natively, so a real dub project
'just' runs under it*". The first clause — **"executes project source"** — is
assumed, not built. `ai/plans/value.md` (Track B) likewise assumes execution
works and concerns itself only with how values are *represented*; it states (its
own words) that "we cannot measure until FFI works, because measuring means
running real dub projects' unittests." Both plans lean on an interpreter that
can run arbitrary project code. It cannot yet. This plan is that missing half.

The gap was found concretely: `bin/bench.sh -b interpreter --dub cerealed`
does not run. The surface error blamed `realloc` and CTFE; §5 shows that was a
masking artifact and the real failure is the interpreter hitting project
constructs it does not implement.

## 1. Goal

`Interpreter` executes the full statement/expression surface a real dub package
(driving fixture: **cerealed**) puts in front of it, so that
`runTests(Interpreter, modules)` produces the same per-unittest results as
`SystemLinker`. Native dependency leaves are out of this plan — they are
`ai/plans/ffi.md`'s job, and that path already works (§4). This plan covers only
the code the interpreter must execute *itself* to reach those leaves with the
right values.

The measure of done is empirical and external: a real package's unittest suite
runs green on `Interpreter` against the `SystemLinker` oracle. That same gate is
the prerequisite `value.md` needs before it can measure any representation, so
this plan unblocks the representation track as well as the FFI terminal goal.

## 2. Non-goals

```text
- native dependency calls (body-less leaves): owned by ai/plans/ffi.md §34;
- the Bytecode/IR backends' execution (ai/plans/bytecode.md);
- value representation choice (boxed vs native layout): ai/plans/value.md;
- new language features DMD does not lower for us (we execute DMD's AST, not
  raw source — templates and `static foreach` arrive pre-lowered);
- performance of the interpreter (correctness first; latency is value.md's axis).
```

## 3. Oracle

`SystemLinker` (compiled, linked, executed native D) is the single behaviour
oracle, per `ai/plans/single-oracle.md` and `AGENTS.md`. Every fixture asserts
the same source on `SystemLinker` (passes) and `Interpreter` (red before, green
after). `Ctfe` is **not** an oracle here and never the definition of correct
behaviour — a point this plan was born from: the original failure surfaced
DMD CTFE's diagnostic as if it were authoritative (§5).

Per `AGENTS.md`: adding or changing a test needs approval first; promoting an
existing oracle-backed matrix fixture to `Interpreter` is pre-approved. Fixtures
live in `tests/ut/backends/runner/ct/` (pure interpretation) and `rt/` (runtime
/ FFI). This plan's fixtures are almost all `ct/` — they exercise interpreter
execution, not the native boundary.

## 4. Relationship to the FFI and representation plans

```text
ffi.md §34     calls body-less native leaves. DONE and not on this plan's path
               for the failures in §7 (verified §5: the FFI chokepoint is never
               reached — the interpreter fails earlier, executing source).
value.md       how the interpreter represents aggregate Values. Assumes
               execution works; this plan delivers that assumption. The two meet
               only where a missing feature is really a missing Value *kind*
               (e.g. a first-class delegate value) — those are flagged per-rung.
bytecode.md    a different backend; native-layout execution. Out of scope.
```

This plan does not duplicate or modify FFI work. Where a cerealed failure turns
out to need a native leaf (e.g. a sourceless Phobos function), that rung defers
to `ffi.md` rather than reimplementing it.

## 5. The masking bug: CTFE-as-diagnostic (Phase 0, prerequisite)

**Status: first assignment target fixed for this PR slice.** The approved red
test now covers the behaviour the interpreter must support: assigning through a
`ref`-returning member call mutates the returned lvalue. The green
implementation handles that ref-return call assignment instead of pinning the
old unsupported-assignment diagnostic.

The reported failure was:

```text
skipping cerealed interpreter: `realloc` cannot be interpreted at compile time,
  because it has no available source code
```

This is **not** an FFI failure and **not** even the interpreter's real error. It
is emitted by DMD's own CTFE engine (`dmd.dinterpret`, the
"cannot be interpreted at compile time" site), reached through this chain:

```text
Interpreter.eval (impl.d ~24) runs a cerealed unittest
  -> Walker throws "Unsupported interpreter assignment target." (a real gap)
  -> eval's catch calls interpreterDiagnostic(msg, fd)        (impl.d ~38)
  -> ONLY for that message, it calls ctfeDiagnostic(fd)
       (quickbite.frontend.dmd.ctfe) to "improve" the wording
  -> ctfeDiagnostic builds a CallExp and runs DMD ctfeInterpret on it
  -> CTFE recurses into cerealed and hits body-less realloc
  -> DMD CTFE emits "realloc cannot be interpreted at compile time"
  -> that message REPLACES the interpreter's real error and becomes the skip
```

Verified by instrumentation: probes at every quickbite FFI / no-source site
never fire; the message originates in the embedded DMD CTFE engine; and the
`ctfeDiagnostic` path is reachable *only* when the underlying error is
`Unsupported interpreter assignment target` (`isUnsupportedInterpreterAssignmentDiagnostic`),
so its firing proves the true blocker is an unsupported assignment.

`ctfeDiagnostic` made sense when the interpreter *mimicked* CTFE semantics
(rejecting body-less leaves as CTFE does), so CTFE's wording was authoritative.
Since FFI landed, the interpreter calls those leaves at runtime; CTFE is no
longer the truth (`single-oracle.md`), and harvesting its diagnostic now
**hides** the interpreter's real, actionable error behind a misleading one.

**Fix direction.** Do not assert that the interpreter should fail with a generic
unsupported-assignment diagnostic when compiled D can execute the program. This
PR fixes the first concrete assignment target exposed by the masking bug:
assignment through a `ref`-returning member call.

**Caveat.** A characterization test may assert the old CTFE-style wording for
the interpreter; it must be updated under the approval rule. This is the only
behaviour change that is a *fix* rather than a *feature*, so it leads.

**Phase 0 test status.** The approved test in
`tests/ut/backends/runner/ct/diagnostics.d` now executes
`box.slot() = 42` where `slot` returns `ref int`, and asserts the assignment
updates `box.value`. This removes one real source of the bad generic
unsupported-assignment failure.

Before Phase 0 landed, **every** interpreter gap below was invisible — they all
collapsed to the same misleading `realloc`/CTFE line. That is why this was the
prerequisite.

## 6. How the gap was measured (reproducible)

With Phase 0 applied and a throwaway probe in `benchmarks/cli.d` that prints
*every* failing `TestResult` (the bench normally prints only the first), one run
enumerates the whole gap set:

```text
bin/bench.sh -b interpreter --dub cerealed
```

The probe is throwaway; a small permanent improvement is worth landing
separately: a `--list-failures` / verbose bench mode so this is repeatable
without patching. cerealed is the driving package because it is small,
dependency-light, struct/serialisation-heavy (so it stresses field iteration and
byte buffers), and already has a large `ct/cerealed.d` fixture to distil from.

## 7. The empirical gap inventory (cerealed, Interpreter)

Distinct interpreter failure **classes** across cerealed's 32 modules, by
frequency (one run, deduplicated by message):

```text
count  class                                          first seen
   68  Expected struct.                               decode.d, encode_decode.d, bugs.d, classes.d
    7  Unsupported eval expression: tuple             decode.d:235, encode.d:196
    7  Expected integer-compatible scalar.            encode.d:95, encode_decode.d:75
    6  Unsupported interpreter assignment target.     scopebuffer.d:302, cerealiser_impl.d:23
    3  Unsupported eval call.                          classes.d:80, encode.d:125
    2  <corrupted/garbage message>                    (suspected wchar/dchar or memory bug)
    2  index [18446744073709551615] out of bounds     (size_t underflow)
    2  Expected pointer.
    1  pointer slice `[0..1]` exceeds block `[0..0]`   scopebuffer.d (ScopeBuffer length tracking)
    1  Unsupported eval expression: concatenateAssign  cerealiser_impl.d:13 (non-scalar `~=`)
```

**Counts are symptoms, not independent root causes.** The 68 `Expected struct`
failures almost certainly share one or a few roots — cerealed iterates struct
fields via `.tupleof`, which the interpreter does not handle (the 7 `tuple`
gaps), so the field walk fails and downstream code that expects a struct value
gets nothing. Triage (root-cause clustering) is the first action of each rung,
not the frequency count.

The bottom three (garbage message, `size_t` underflow, pointer-slice over the
allocated block) smell like **correctness bugs in existing paths**, not unbuilt
features — they get characterized against the oracle and fixed, not "added".

## 8. Method: one standalone red/green unit test per reason

**The core rule.** For *each* reason the interpreter cannot run cerealed's
unittests today — i.e. each gap class / root cause in §7 — the implementer
writes a **standalone unit test that passes on `SystemLinker` and fails on
`Interpreter`**. "Standalone" is load-bearing: the test must **not import,
build, or otherwise depend on cerealed** (or any dub package). It is a minimal,
hand-written reproduction of the construct — derived from *understanding* the
cerealed failure, but self-contained — so it lives in `ct/`, runs with no
package present, and stays meaningful long after cerealed changes. cerealed is
the *discovery* instrument (§6); the regression suite that proves each fix is
these independent fixtures, not the package.

```text
1. Phase 0 (§5) lands first so the real interpreter errors are visible at all.
2. For each reason in §7, write ONE standalone ct/ fixture (no cerealed
   dependency) reproducing that construct: green on SystemLinker (the oracle),
   red on Interpreter. Get it approved (AGENTS.md) before adding it. This is the
   red test that drives the rung.
3. Fix the ROOT until the fixture is green on Interpreter too. Then re-measure
   §6 and let the cerealed frequency table collapse.
4. A rung is "done" when: its standalone fixture passes on both backends, its
   class is gone from the cerealed §7 inventory, and ct/ and rt/ show no
   regression.
5. Re-run §6 between rungs: closing one class routinely reveals the next, deeper
   one previously hidden behind the first thrown error per unittest. Each newly
   revealed reason gets its own standalone red/green fixture in turn.
```

A single reason may need more than one fixture (e.g. read vs write, or per
element width), but each fixture still pins exactly one construct and obeys the
green-on-oracle / red-on-Interpreter rule. Fixtures follow the existing `ct/`
convention: a `static foreach (backend; AliasSeq!(Ctfe, Interpreter,
BytecodeNewCore, SystemLinker, LLVMJit))` matrix wrapping
`runBackendSourceFixtureTests!backend(q{ ... })` (see
`tests/ut/backends/runner/ct/cerealed.d` for the style — that file is itself
standalone distilled snippets, not a cerealed import).

## 9. The rungs (ordered by leverage)

Ordered by how much of the cerealed inventory each unblocks, root-cause first.
Re-measure (§6) after each; the order may shift as roots collapse classes.
Anchors are approximate (the file is edited often on other branches — re-grep
and re-read before editing, per `ai/mistakes.md`).

### 9.1 Rung 1 — struct field iteration (`.tupleof` / `TupleExp`)

**Contract.** Evaluate a `TupleExp` and `foreach` over a struct's `.tupleof`,
the field walk cerealed (and any (de)serialiser) is built on. Suspected root of
the 68 `Expected struct` failures as well as the 7 `tuple` ones.

**Oracle fixture.** A struct with mixed-type fields; `foreach (ref f; s.tupleof)`
that reads and writes each field; assert the mutated struct.

**Slice status.** The standalone fixture
`struct.tupleofForeachRefReadsAndWritesFields` now covers DMD-lowered
`foreach (ref field; record.tupleof)` reads and writeback to mixed scalar
fields. The interpreter handles the lowered ref local as a struct-field alias.

**In scope.** `TupleExp` evaluation; `.tupleof` as an iterable in the
DMD-lowered `foreach`; tuple element lvalues for the writeback half.
**Out of scope.** Arbitrary `AliasSeq` of types, `TypeExp` tuples.

**Anchors.** `runExpression` `TupleExp` fall-through (`impl.d` ~1125, generic
"Unsupported eval expression"); the `UnrolledLoopStatement` handler
(`impl.d` ~214) DMD lowers `.tupleof` foreach into; `Value.Struct`
(`lang/package.d`). **Done.** `tuple` and most `Expected struct` classes drop
out of the §7 inventory; fixture green on both backends.

### 9.2 Rung 2 — residual `Expected struct`

**Contract.** Whatever `Expected struct` failures survive Rung 1 — places the
interpreter coerces a non-`Struct` `Value` where a struct is required (struct
returns, struct literals through a path that loses the kind, nested struct
fields). Triaged from the post-Rung-1 inventory, not guessed now.

**Oracle fixture.** Per distinct residual root, distilled from the surviving
`decode.d`/`encode_decode.d` lines. **Done.** `Expected struct` gone from §7.

**Slice status.** The standalone fixture
`struct.templatedConstructorPreservesDynamicArrayField` now covers templated
struct constructors that assign a dynamic-array field. The interpreter treats
the instantiated `this` function as a constructor for receiver seeding and
returns the initialized `this` value, matching `SystemLinker`.

### 9.3 Rung 3 — unsupported assignment targets + non-scalar `~=`

**Contract.** The assignment lvalue forms cerealed's buffer code needs:
`scopebuffer.d` and `cerealiser_impl.d` writes (6×), plus
`concatenateAssign` for non-scalar element append (1×).

**Oracle fixture.** Distilled from the ScopeBuffer/cerealiser write sites: an
index/slice/field assignment through the unsupported base form, and a
`buf ~= arrayOrStruct` non-scalar append.

**In scope.** The specific lvalue shapes in the six throw functions
(`writeLocation`, `writeIndexLocation`, `runIndexAssignExpression`,
`runAssocArraySlotAssignExpression`, `runNestedIndexAssignExpression`,
`runSliceAssignExpression`, `impl.d` ~3210–3582) that cerealed hits; non-scalar
`concatenateElemAssign`. **Out of scope.** Tuple/destructuring lvalues and
write-through-global-pointer unless cerealed needs them.

**Done.** `Unsupported interpreter assignment target` and `concatenateAssign`
gone from §7.

### 9.4 Rung 4 — `Expected integer-compatible scalar` (7×)

**Contract.** The scalar-coercion failures in `encode.d`/`encode_decode.d` —
likely enum/char/width handling where the interpreter expects a plain integer
`Value` but holds an `EnumValue`/char/pointer. Triage first; may be one root.

**Oracle fixture.** Distilled from the `encode.d:95`-style sites. **Done.**
class gone from §7.

### 9.5 Rung 5 — `Unsupported eval call` (3×)

**Contract.** The call shapes in `classes.d`/`encode.d` the dispatcher rejects
(`impl.d` ~1837). Determine per-site whether it is an interpretable source call
the dispatcher misses, or a native leaf that should route to `ffi.md` — the
latter is deferred, not built here.

**Done.** Each site either interprets, or is documented as an `ffi.md` rung.

### 9.6 Rung 6 — correctness bugs in existing paths

**Contract.** The three low-count, high-suspicion classes: the corrupted
message (suspected `wchar`/`dchar` or buffer bug), the `size_t` underflow
`index [18446744073709551615]`, and the pointer slice exceeding its allocated
block (`ScopeBuffer` length/`malloc` metadata). These are likely regressions in
already-supported paths.

**Oracle fixture.** Each characterized against `SystemLinker`: a minimal repro
that the interpreter currently gets wrong. **Done.** All three classes gone;
fixtures pin the corrected behaviour.

## 10. Done

```text
- Phase 0 (§5) landed: the interpreter's real error surfaces; no CTFE-as-truth.
- The §7 inventory for cerealed is empty: every cerealed unittest runs on
  Interpreter and agrees with SystemLinker.
- `bin/bench.sh -b interpreter --dub cerealed` produces a post-parse row for the
  interpreter (no skip), and bin/ut --random is green.
- Each rung left an approved oracle-backed ct/ fixture; no ct/ or rt/ regression.
```

At that point the FFI terminal goal (`ffi.md` §34.1) is actually reachable for
cerealed, and `value.md` has the running real-package suite it needs to measure
representations.

## 11. Beyond cerealed

cerealed is the first driving package, not the finish line. Once it is green,
repeat §6/§8 against a second, less struct-centric package (one exercising
ranges, AAs, classes, or `ref` slice writeback) to surface the next gap tier.
The architecture survey flagged the likely next blockers: GC array growth
(`assumeSafeAppend`/`reserve`/capacity), `ref ubyte[]` writeback fidelity across
the FFI marshalling seam, sourceless-Phobos coverage (routes to `ffi.md`), and
captured/`scope`/`lazy` delegates (where a first-class delegate `Value` kind
meets `value.md`). Each gets its own rung under this plan when a real package
forces it — same loop: measure, distil, approve, red → green.

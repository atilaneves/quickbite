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

**Status: closed.** The `ctfeDiagnostic` harvesting path
(`quickbite.frontend.dmd.ctfe`, deleted) no longer exists: the interpreter's
`eval` reports its own exception message verbatim. The characterization test
that pinned the CTFE-style wording for a REPL `File` open
(`repl.backend.runtimeOnlyFileOpenReportsNativeBoundary`) was superseded by
`repl.backend.runtimeFileOpenSucceeds` — the open now works (§9.8). Earlier
slices had fixed the first masked assignment target (assigning through a
`ref`-returning member call).

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

**Re-measured 2026-07-06, after §9.8 and with the §5 masking machinery
deleted** — the first inventory whose messages are the interpreter's own.
91 failing unittests across cerealed's 32 modules, deduplicated by message:

```text
count  class                                            plan home
   35  Unsupported eval expression: tuple               Rung 1 (reopened)
   21  Unsupported eval expression: identifier          triage with Rung 1
    8  Expected integer-compatible scalar.              Rung 5
    5  Unsupported interpreter assignment target.       Rung 3 (reopened)
    6  index [18446744073709551615 / 0] out of bounds   Rung 7 (underflow)
    4  pointer slice exceeds allocated memory block     Rung 7 (ScopeBuffer)
    3  cannot read uninitialized variable `.grain.b`    void-init field reads
    2  Expected array.                                  triage
    2  <corrupted/garbage message>                      Rung 7 (wchar/dchar)
    1  [0, 0, 0, 0] != [0, 0, 0, 5]                     silent wrong answer
    1  Unsupported cast to ulong from Pointer           pointer→integer cast
    1  gc_getArrayUsed has no available source          GC array growth (§11,
                                                        arrived early)
    1  Unsupported eval call.                           Rung 6
    1  Unsupported eval expression: cast_               triage
```

**Counts are symptoms, not independent root causes.** The 35 `tuple` and 21
`identifier` failures almost certainly share one or a few roots in tuple
positions Rung 1's `foreach` lowering does not cover. Triage (root-cause
clustering) is the first action of each rung, not the frequency count.

The `size_t` underflow, pointer-slice-over-block, corrupted-message, and the
one silent value mismatch are **correctness bugs in existing paths**, not
unbuilt features — they get characterized against the oracle and fixed, not
"added". The silent mismatch and the corrupted message are the most urgent:
they are wrong answers rather than honest refusals.

**2026-07-07 (bench-dub-corpus item 3).** The `2× Expected array.` triage
line is root-caused and fixed: slice assignment through pointers rebuilt
the lvalue as a detached `Array` — throwing for native pointers (mode 1),
silently severing aliasing for D pointers (mode 2, Rung 7 family), plus
the `= void` sibling where taking `.ptr` of a still-void static array
degraded to an untracked local pointer (mode 3, one of Rung 3's 5×
`Unsupported interpreter assignment target`). Standalone fixtures:
`realloc.sliceAssignWritesNativeMemory` (rt/cstdlib),
`pointer.sliceAssignmentWritesArrayStorage` and
`pointer.indexAssignmentWritesVoidInitialisedArray` (ct/arrays). Audit
note: `writeBackSliceElements` (the array-op `+=` lowering's splice copy)
still rebuilds a pointer-typed slice base as a detached local `Array` —
same latent silent-lost-write class, needs its own exposing fixture.
Re-measure (§6): done 2026-07-07, see the close-out entry below.

**2026-07-07 (bench-dub-corpus follow-on).** The automem
`Unsupported eval expression: address of call` class (the largest
surviving two-backend disagreement) is root-caused and fixed:
`runAddressExpression` had no branch for AddrExp(CallExp), i.e. the
address of a ref-returning call. phobos' `theAllocator` is this shape on
every fetch — its ref-returning ternary lowers to
`return *(cond ? &p : &setupThreadAllocator())` — so every automem
vector test refused. The fix runs the callee in `addressOfRefReturn`
mode (the return statement evaluates its expression as an lvalue
address, so pre-return side effects run exactly once) and remaps a
returned ref-parameter address onto the caller's argument lvalue so
writes through the pointer stick. Standalone fixtures:
`pointer.addressOfRefReturningCallAliasesArgument` and
`pointer.refTernaryReturnLowersToAddressOfCall` (ct/expressions).
automem re-measure: 0× address of call (was 35×); the vector tests now
run `setupThreadAllocator` for real and stop honestly at the next
rungs — `pthread_mutexattr_init` FFI (no available source) and
`cannot read uninitialized variable .trustedMoveImpl.result`. The
sibling `Unsupported interpreter assignment target: call` class
(ref-returning call as assignment target; 10× automem) is still open —
`writeRefReturningCallLocation` only handles DotVarExp receivers and
skips the callee body, the same shortcut this fix retired for
address-of; rebuild it on `addressOfRefReturn` mode when that rung is
worked.

**2026-07-07 (assignment-target-call rung).** The interpreted side of
the sibling class is fixed: `writeRefReturningCallLocation` is rebuilt
on `assignToRefReturn` mode (the assignment counterpart of
`addressOfRefReturn`) — run the callee for real, and at the executed
return statement write the assigned value through the returned lvalue
via `writeLocation`, whose PtrExp branch already handles the
`*(cond ? &a : &b)` ternary lowering. This retires both defects of the
old shortcut: free functions refused outright (`Unsupported interpreter
assignment target: call`), and member calls wrote to the *textually
first* return expression without executing the body — pre-return side
effects silently skipped. `refReturnExpression` is gone. Standalone
fixtures: `refCall.assignmentToRefReturningCallWritesArgument`,
`refCall.assignmentToRefTernaryReturnWritesChosenBranch`,
`refCall.assignmentToMemberRefReturnRunsCalleeBody` (ct/expressions;
BytecodeNewCore stays red and is omitted). automem re-measure: the 10×
`assignment target: call` mismatches **remain** — located diagnostics
show all ten are `fakePureErrno() = errnosave` (druntime
core/memory.d:1062/:1070), a **native** ref-returning body-less
function, i.e. a different root cause: `callViaLibffi`
(source/quickbite/ffi/core.d:353) marshals the return as
`type.next.toBasetype` and never consults `isref`, so a native ref
return's ABI pointer is read as if it were the value — the read at
memory.d:1060 yields the low bits of the errno address (a latent
silent-wrong-answer for pure reads), and assignment has no path at
all. Needs its own rung: ffi ref-return support (return the pointer,
deref for rvalue reads, write through it for assignment), rt/ exposing
fixtures against a body-less `ref`-returning libc accessor.

**2026-07-07 (bench-dub-corpus close-out).** `ai/plans/bench-dub-corpus.md`
is folded into its owning plans and deleted; the "item 3" / "follow-on"
citations above refer to that document's work items (PRs #352–#356 plus
the two rungs above), now git history. Its surviving content lands here,
in `ffi.md` §35.9 (the native ref-return defect above, now a tracked FFI
work item), in `bench.md` (tardy run-executor crash; `bin/bench` build
misconfiguration; crash-containment motivation for fork-per-package),
and in `ai/plans/link-set-pollution.md` (the template-instance pollution
flake).

**2026-07-07 re-measure (master e7e698c8, `-b interpreter
-b system-linker`, full per-test mismatch lists).** This supersedes the
snapshot the close-out first carried, which had copied the plan's
pre-#359 verification state: in particular fearless's `address of
dotVariable` was ALREADY CLEARED by the address-of-call fix (PR #359)
and is not a live class. All four packages prepare 100% and print a
frontend row; all post-parse timing is skipped on disagreement (or, for
tardy, backend error). Deduplicated inventories:

```text
automem  14/14 prepared, 111 mismatching tests (was 14 before #359/#363
         — the fixes let tests run much deeper, fanning out onto the
         common theAllocator initialization path):
   48  pthread_mutexattr_init no available source     ffi.md §35.10
   26  Unsupported eval expression: cast_             triage
   18  cannot read uninitialized variable
       `.trustedMoveImpl.result` in ctfe              triage
   10  Unsupported interpreter assignment target:
       call (all fakePureErrno)                       ffi.md §35.9
    3  Unsupported eval call.                         Rung 6 family
    2  Unsupported eval statement: Error in
       test_allocator.TestAllocator.deallocate        NEW class, triage
    1  Unsupported eval expression: tuple             Rung 1 family
    1  Unsupported binary lhs type.                   triage
    1  false != true (silent)                         Rung 7 family
    1  Expected array. (new automem site)             triage

fearless  7/7 prepared, 8 mismatching tests — address of dotVariable
          GONE (cleared by PR #359):
    3  pthread_mutexattr_init no available source     ffi.md §35.10
    3  cannot read uninitialized variable
       `.trustedMoveImpl.result` in ctfe              triage
    2  Unsupported eval expression: cast_             triage

cerealed  32/32 prepared, 91 mismatching tests — same total as the
          2026-07-06 table above, slightly reshaped:
   35  Unsupported eval expression: tuple             Rung 1 (reopened)
   21  Unsupported eval expression: identifier        triage with Rung 1
    8  Expected integer-compatible scalar.            Rung 5
    6  index [18446744073709551615] out of bounds     Rung 7 (underflow)
    3  cannot read uninitialized variable `.grain.b`  void-init reads
    2  pointer slice exceeds allocated memory block   Rung 7 (ScopeBuffer)
    2  ScopeBuffer value mismatches (L302
       `[ , a] != "xa"`, L345) — replaced the fixed
       `Expected array.` class                        Rung 7 (ScopeBuffer)
   11  corrupted/garbage messages                     Rung 7 (wchar/dchar)
    1  Unsupported interpreter assignment target:
       slice of dotVariable (down from 5×, now
       located)                                       Rung 3
    1  index [0] out of bounds for length 0           Rung 7
    1  [0, 0, 0, 0] != [0, 0, 0, 5] (silent)          Rung 7
    1  gc_getArrayUsed no available source            §11 (GC growth)
    1  Unsupported eval call.                         Rung 6

tardy  by path: 22/22 prepared, frontend row prints; the system-linker
       leg's run-executor crash (bench.md) skips the whole package's
       post-parse timing INCLUDING the interpreter leg. By registry
       name: correctly unpreparable
       (`ut/polymorphic.d(24,12): scope variable ...`)
```

**2026-07-08 (post-#373 automem re-measure, master ce8b5851).** The ffi
native-ref-return fix (PR #373, `ffi.md` §35.9) retires the 10×
`Unsupported interpreter assignment target: call` class; the same ten
tests now proceed deeper and fail as 10× `Expected struct.` — a NEW
automem class (Rung 2 was cerealed-scoped and closed; this is a fresh
site), needs triage and a standalone fixture per §8. automem total
unchanged at 111; all other classes byte-identical to the 2026-07-07
table above. `pthread_mutexattr_init` (48×, `ffi.md` §35.10) remains
the dominant class.

**2026-07-08 (interpreter-rung-triage, master 8633929d).** Re-measure
confirms the cerealed inventory byte-identical to the 2026-07-07 table
(91 mismatches). A throwaway location probe (§6 pattern: source loc +
expression text appended to the unsupported diagnostics, reverted after
the run) collapses the three reopened symptom buckets into exactly
**three single-site clusters** — one root cause each, no fan-out:

```text
35× tuple       ONE site: std.typecons.Tuple's constructor
                (`field[] = values[]`), i.e. a TupleExp of per-field
                assignments in expression position. Every one of the 35
                tests reaches it through unit_threaded's `shouldThrow`
                (its `threw` helper builds `tuple!("threw","info")(…)`).
                Root: `runExpression` has no TupleExp branch at all —
                the expression falls to the generic fall-through
                (impl.d ~1208). Rung 1, re-scoped below.
21× identifier  ONE site: std.internal.entropy's module-scope
                `_entropySource = defaultEntropySource`. All 21 are
                tests/property.d (20 static-foreach instances + 1),
                via unit_threaded `check!` → std.random. NOT rung 1's
                root: the initializer is a still-unresolved
                IdentifierExp because only root modules get semantic2
                (compiler.d `parseRootModulesLocked`); the dataseg
                materialization path (impl.d ~1193) evaluates the raw
                `_init`. New Rung 9 (§9.9).
 1× assignment  ONE site: the vendored scopebuffer.d put
    target      (`buf[used .. newlen] = s[]`), from ScopeBuffer's own
                unittest: a default-initialised buffer receiving an
                empty put — a zero-length slice assignment through a
                null pointer, a no-op in compiled D. Root:
                `runPointerSliceAssignExpression` (impl.d ~4322) checks
                pointer provenance before element count. Rung 3.
```

Each cluster is verified by a standalone repro through `bin/bench`
(interpreter vs system-linker): identical diagnostic at the identical
site, oracle leg green. The proposed exposing fixtures live in the rung
sections below and await approval; no existing matrix fixture covers
any of the three constructs, so no pre-approved promotions applied.

**2026-07-08 (Rung 1 landed, TupleExp).** §9.1's fix (a `TupleExp`
branch in `runExpression`) closes the 35× `tuple` cluster: re-measure
shows 0× `tuple` in cerealed. The 35 tests, which died on their final
`shouldThrow → tuple!(…)` assertion, now run past it and stop at the
next deeper class — `Unsupported eval call.` grew 1× → 36×, the newly
exposed blocker (triage / Rung 6 family). cerealed total is unchanged
at 91; the rest of the inventory is byte-identical to the table above
(the `identifier` cluster — Rung 9/§9.9 — is untouched and remains 21×).

**The goal is support, not pinned refusal** (user directive, 2026-07-07).
The `rt/concurrency.d` `thisTid` fixture currently lets the Interpreter
leg pass on *either* oracle agreement *or* a structured unsupported
diagnostic. That acceptance was crash-scoped triage (the item's target
was "never dies"), not the end state: the goal is that the interpreter
**runs** these constructs and agrees with `SystemLinker` — here and for
the surviving disagreements above. Do not add further tests that pin an
unsupported diagnostic as acceptable interpreter behaviour; distil each
gap into a red/green fixture per §8 and fix the root.

The original masked-era inventory (68× `Expected struct` on top) is in git
history; it is no longer meaningful — Phase 0's full closure and §9.8 both
reshaped it.

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

**Matrix width and refusals (user guidance, 2026-07-07).** Each fixture runs
on the widest backend matrix it can express. A backend for which the fixture
stays red after the rung's fix is *omitted* from the fixture's backend
list — the omission is the documentation. Do **not** pin a structured
unsupported diagnostic with `shouldThrowWithMessage`, especially for
backends still in development (`BytecodeNewCore`): such pins turn every
feature landing into a test-update chore, and per §7's
support-not-refusal directive a pinned refusal is never the end state.

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
(`lang/package.d`).

**Status: reopened by the 2026-07-06 remeasure; triaged 2026-07-08 (§7).**
The fixture stays green. The location probe shows all 35 `tuple` failures
(count as of 2026-07-08) are ONE construct the original rung scoped out:
a `TupleExp` in *expression position* — DMD's lowering of tuple assignment
(`field[] = values[]` in std.typecons.Tuple's constructor, equivalently
`target.tupleof = source.tupleof`) into
`AliasSeq!(target.head = source.head, target.tail = source.tail)`.
`runExpression` has no `TupleExp` branch, so it falls to the generic
fall-through (impl.d ~1208; only the `UnrolledLoopStatement` foreach
lowering ever consumes tuples today). Every failing test reaches it via
unit_threaded's `shouldThrow` → `threw` → `tuple!("threw","info")(…)`,
which is why the class blankets cerealed: the tests die on their *last*
assertion line — the preceding grain/shouldEqual chains already pass.
The 21× `identifier` bucket does NOT share this root; it is a distinct
defect, now §9.9.

The fix direction: evaluate a `TupleExp` by running `e0` (the
side-effect prefix) if present, then each element expression in order —
for the assignment-tuple case the elements are ordinary assignments the
interpreter already handles individually.

**Done (2026-07-08).** `runExpression` now has a `TupleExp` branch
(`runTupleExpression`, impl.d) mirroring the IR lowering
(`lowering.d` `lowerTupleExpression`): run `e0` if present, then each
element in order, returning the last (the value is discarded in the
statement-expression positions this arises in). Two standalone
fixtures landed in ct/structs.d — the headline
`struct.tupleConstructionFromLocals` (`Tuple!(int, int)(first, second)`)
and the dependency-free distillation
`struct.tupleofAssignmentCopiesFields`
(`target.tupleof = source.tupleof`) — each green on
`Ctfe, Interpreter, SystemLinker, LLVMJit` (BytecodeNewCore omitted per
§8; still red there). Re-measure (§6): the 35× `tuple` class is gone
from the cerealed inventory (0×); the 35 tests now progress past their
final `shouldThrow` assertion and surface the next deeper class —
`Unsupported eval call.` rose 1× → 36× (triage / Rung 6 family), the
newly-revealed blocker. cerealed total unchanged at 91.

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

**Slice status.** The standalone fixture
`dynamicArray.fieldConcatenationAssignment` now covers non-scalar dynamic-array
`concatenateAssign` through a struct field (`writer.bytes ~= chunk`). The
interpreter routes that DMD AST expression through the existing concatenation
element logic and writes the result back with `writeLocation`.

**Slice status.** The standalone fixture
`dynamicArray.localConcatenationAssignment` now covers non-scalar dynamic-array
`concatenateAssign` through a local variable (`values ~= chunk`). The
interpreter handles that local `VarExp` target with the existing concatenation
element logic and writes the result back with `writeLocation`.

**Status: reopened by the 2026-07-06 remeasure; triaged 2026-07-08 (§7).**
`concatenateAssign` is gone, and §9.8 closed further assignment shapes
(struct-field slice bases). Of 2026-07-06's 5×, four were retired by the
2026-07-07 pointer-slice fixes; the ONE survivor (count as of
2026-07-08) is located: the vendored `cerealed/scopebuffer.d` `put` —
`buf[used .. newlen] = s[]` — hit by ScopeBuffer's own unittest, which
`put`s empty slices into *default-initialised* buffers. That makes
`used == newlen == 0` and `buf` null: a **zero-length** slice assignment
through a null pointer, which compiled D executes as a no-op (nothing is
written). `runPointerSliceAssignExpression` (impl.d ~4322) evaluates the
base pointer and checks its provenance (native vs tracked-array) before
looking at the element count, so a pointer with no writable provenance
refuses even when there is nothing to write. Fix direction: an empty
range (`upper == lower`) writes zero elements and returns the rhs value
before any provenance check, matching compiled D.

**Proposed exposing fixture (awaits approval; verified red on
`Interpreter` with `Unsupported interpreter assignment target: slice of
dotVariable`, green on `SystemLinker`, via standalone `bin/bench` repro
2026-07-08).** ct/arrays.d, pointer.* family:

```d
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
```

Backend matrix per §8; `Ctfe`'s treatment of a null-pointer slice is
determined at landing and omitted or characterized per
`single-oracle.md` if it diverges.

**Done (2026-07-08).** `runPointerSliceAssignExpression` (impl.d ~4356)
now short-circuits an empty range (`upper == lower`) — after evaluating
the rhs, before any provenance check — returning the rhs value, matching
compiled D's no-op for a zero-length write. Standalone fixture
`pointer.emptySliceAssignmentThroughNullPointerIsNoOp` (ct/arrays.d,
the §9.3 `Buffer.put(empty)` shape) is green on
`Ctfe, Interpreter, SystemLinker, LLVMJit` — `Ctfe` treats the
null-pointer empty slice as the same no-op, so no divergence to
characterize. Closes the last cerealed `Unsupported interpreter
assignment target: slice of dotVariable` (1×).

### 9.4 Rung 4 — `VarExp(SymbolDeclaration)` struct default init

**Contract.** Evaluate the `VarExp` DMD emits for a struct
`SymbolDeclaration` when a real program reads a struct default initializer.
The result must match compiled D, including explicit non-zero field
initializers; plain field-type zeroing is not enough.

**Oracle fixture.** Pre-approved:

```d
struct Header {
    ubyte tag = 7;
    int code = 42;
}

unittest {
    auto header = Header.init;

    assert(header.tag == 7);
    assert(header.code == 42);
}
```

**In scope.** The `runExpression` `VarExp` branch where `var.var` is a
`SymbolDeclaration` with a `TypeStruct`; preserving DMD default-initializer
semantics, likely by evaluating the aggregate's default-init literal rather
than calling the existing zero/default-by-type `defaultValue(Type)` helper.
**Out of scope.** `__traits(initSymbol, S)` as `const(void)[]`, initializer
symbol addresses, and non-struct `SymbolDeclaration` cases unless a remeasure
proves cerealed reaches them.

**Slice status.** The standalone fixture
`struct.defaultInitPreservesExplicitFieldInitializers` covers `Header.init`
against `Interpreter` and `SystemLinker`. The interpreter now handles
`VarExp(SymbolDeclaration)` for struct initializer symbols by evaluating DMD's
`defaultInitLiteral`, preserving explicit field initializers. In this harness
the exact fixture was already green before the production change.

**Done.** The fixture is green on `Interpreter` and `SystemLinker`, and
`bin/bench.sh -b interpreter --dub cerealed` no longer aborts with `SIGILL`.
Remeasure §7 immediately afterward; then proceed to the next visible class.

**Post-Rung-4 remeasure.** The first remeasure exposed the next concrete
assignment blocker in `ScopeBuffer.put`: `data[index] = value` where `data` is
a pointer into D array storage. The standalone fixture
`pointer.indexAssignmentWritesArrayStorage` now covers that language behaviour
against `Interpreter` and `SystemLinker`. The interpreter routes non-native
pointer index assignment through tracked array storage before the associative
array slot fallback, preserves slice-parameter backing storage, and writes back
static-array storage only after an actual tracked pointer write.

The `realloc`-flavoured skip this remeasure used to print is gone for good:
§5's masking machinery is deleted, so the bench now reports the
interpreter's own first error, and the probe-based full listing (§6) is what
produced the current §7 inventory.

### 9.5 Rung 5 — `Expected integer-compatible scalar` (8×)

**Contract.** The scalar-coercion failures in `encode.d`/`encode_decode.d` —
likely enum/char/width handling where the interpreter expects a plain integer
`Value` but holds an `EnumValue`/char/pointer. Triage first; may be one root.

**Oracle fixture.** Distilled from the `encode.d:95`-style sites. **Done.**
class gone from §7.

### 9.6 Rung 6 — `Unsupported eval call` (1×)

**Contract.** The call shapes in `classes.d`/`encode.d` the dispatcher rejects
(`impl.d` ~1837). Determine per-site whether it is an interpretable source call
the dispatcher misses, or a native leaf that should route to `ffi.md` — the
latter is deferred, not built here.

**2026-07-08 follow-up: lazy assertion thunks.** After the GC array-capacity
hook slice, the real-package red signal was:

```text
bin/bench.sh -b interpreter --dub cerealed
skipping cerealed interpreter: Unsupported eval call.
```

A throwaway dispatcher-location probe (reverted before commit) identified the
call as unit-threaded's lazy assertion parameter: `expr()` in
`unit_threaded/assertions.d` (`threw`/`shouldNotThrow`). This is interpreter
owned, not FFI: `lazy E expr` arguments were being evaluated before binding, so
the formal held either `Value.undisplayable` for a DMD `FuncExp` wrapper or the
already-evaluated expression value when a lazy parameter was forwarded into
another lazy parameter. The dispatcher then saw `expr()` as a non-callable local
value and threw the generic call diagnostic.

No new standalone fixture was added because this worker did not have approval
to add tests; the existing cerealed bench signal is the red. The interpreter
now records lazy formal parameters as expression thunks with a captured local
snapshot, preserves that thunk when a lazy parameter is forwarded to another
lazy parameter, and evaluates the thunk when the zero-argument lazy parameter is
called.

Re-measure: the `Unsupported eval call.` frontier is gone. The package advances
to the pre-existing corrupted/garbage failure-message class tracked under Rung
7; this is the next visible interpreter blocker.

**Done.** Each site either interprets, or is documented as an `ffi.md` rung.

### 9.7 Rung 7 — correctness bugs in existing paths

**Contract.** The low-count, high-suspicion classes: the corrupted message
(suspected `wchar`/`dchar` or buffer bug), the `size_t` underflow
`index [18446744073709551615]`, the pointer slice exceeding its allocated
block (`ScopeBuffer` length/`malloc` metadata), and — worst of all — the one
silent value mismatch (`[0, 0, 0, 0] != [0, 0, 0, 5]`), a wrong answer with
no diagnostic. These are likely bugs in already-supported paths.

**Oracle fixture.** Each characterized against `SystemLinker`: a minimal repro
that the interpreter currently gets wrong. **Done.** All three classes gone;
fixtures pin the corrected behaviour.

**2026-07-08 follow-up: ScopeBuffer pointer snapshots.** `cerealed`
re-measure after the closed Rung 1/Rung 3/Rung 9 work exposed the next
interpreter-owned red as ScopeBuffer wrong answers (`[\0, a] != "xa"`,
then `"hellobettyeven more"`). No approved standalone fixture existed, so the
real-package bench remained the red signal. `memcpy` now copies scalar elements
into native destinations from the typed source pointer behind `void*` casts,
and pointer index/slice assignment falls back to updating the pointer target
snapshot when the allocation id is known but the owner local has gone out of
scope. The ScopeBuffer mismatches are gone;
`bin/bench.sh -b interpreter --dub cerealed` now advances to `gc_getArrayUsed`
with no source, the GC array-growth frontier in §11.

The concrete trigger was `cerealed` `ScopeBuffer.resize`: it explicitly imports
`core.stdc.string : memcpy` and calls `memcpy(newBuf, buf, used * T.sizeof)`.
The interpreter treats this as a narrow primitive-memory bridge because
`memcpy` erases the element type behind `void*`, while interpreter-owned storage
is still typed `Value`s plus tracked pointer snapshots. The generic native-call
path cannot correctly copy between interpreter-owned storage and native/realloc
memory. This is not an open-ended libc special case; future cleanup can fold it
into a small `memset`/array-copy-like memory-intrinsics layer.

**2026-07-08 follow-up: GC dynamic-array capacity hooks.** The
`gc_getArrayUsed` blocker from §11 is now past the first runtime hook
frontier. No approved standalone fixture existed for this package-only
lowering path, so the red signal was the real-package bench:
`bin/bench.sh -b interpreter --dub cerealed` skipped with:

```text
`gc_getArrayUsed` cannot be interpreted at compile time, because it has no
available source code
```

The interpreter now recognizes the druntime `gc_getArrayUsed`,
`gc_reserveArrayCapacity`, and `gc_shrinkArrayUsed` helpers before the generic
body-less native-call path. `gc_getArrayUsed` reifies the tracked interpreter
allocation behind the incoming array pointer; locals initialized from the
druntime `cast(T[]) gc_getArrayUsed(...)` shape preserve that allocation id so
the subsequent `arr.ptr - curArr.ptr` calculation in
`core.internal.array.capacity` still sees same-allocation pointers.
`reserveCapacity` and `shrinkUsed` evaluate their arguments and return the
scalar result the interpreted capacity code needs.

Re-measure (§6): `gc_getArrayUsed` and the immediate
`Expected pointers into the same allocation.` follow-up are gone. The package
now advances to the pre-existing broader `Unsupported eval call.` frontier.

**2026-07-08 follow-up: overlapping slice assignment diagnostic.** The
existing `dynamicArray.overlappingSliceAssignmentDiagnostic` oracle fixture now
includes `Interpreter` instead of pinning it to CTFE's detailed overlap text.
The interpreter's local dynamic-array slice assignment path now reports
compiled D's `Range violation`, matching `SystemLinker` for this already
rejected overlapping write.

**2026-07-08 follow-up: `emplaceRef` fills uninitialized join buffers.** After
the lazy assertion thunk slice, the real-package red signal was:

```text
bin/bench.sh -b interpreter --dub cerealed
skipping cerealed interpreter: <127 bytes of 0xff rendered as garbage>
```

No approved standalone fixture existed for this package-only frontier, so the
bench remained the red signal. A probe on `InterpretedException` showed the
failing `UnitTestException.msg` had the correct length but every element was
`char.init` (`0xff`). The first failing site was cerealed
`tests/classes.d:42` (`class.with.struct`), whose `shouldEqual` failure message
is built by unit-threaded's `UnitTestException` constructor:
`msgLines.join("\n")`. Phobos `std.array.join` allocates the result with
`uninitializedArray!(char[])` and fills each slot via
`core.internal.lifetime.emplaceRef(result[len++], e)`. The interpreter was
executing `emplaceRef`'s runtime implementation literally: it initializes the
slot, then casts `&chunk` to a wrapper `S*` and writes through `p.payload`.
That pointer-cast wrapper does not alias back to the original array element in
the interpreter's value model, so the write was lost and the buffer stayed
filled with `char.init`.

The interpreter now treats `core.internal.lifetime.emplaceRef!(...)` as the
ref-write primitive it is for this path: evaluate the value argument, write it
through the first ref argument with `writeLocation`, and return `void`.
Re-measure: the corrupted/garbage message class is past. The package now
advances to a readable assertion mismatch at the same first site:

```text
skipping cerealed interpreter: Expected:
tests.classes.ClassWithStruct(DummyStruct(2, 3), 4)
```

That next blocker is no longer message corruption; it is a real class
serialization/equality wrong-answer frontier.

**2026-07-08 follow-up: class references passed by value alias their
object.** The readable `tests/classes.d:42` failure above was root-caused with
a temporary full-message bench probe:

```text
Expected: tests.classes.ClassWithStruct(DummyStruct(2, 3), 4)
     Got: tests.classes.ClassWithStruct(DummyStruct(0, 0), 0)
```

The decoded class object was constructed, but all field writes were lost. A
writeback probe showed cerealed's `Decerealiser.grainClass(T)(T val)` was the
break: `T val` is a by-value class reference. In compiled D, writes through
that copied reference mutate the same object. In the interpreter,
`Value.ClassObject` is immutable value data, so `grainClass`'s local `val`
received `dummy` and `anotherByte`, but the caller's outer `ref val` still held
the default object and was later written back over the decoded value. The
interpreter now writes back changed by-value class parameters to writable class
arguments after interpreted function/member calls, modelling class-reference
field mutation with the existing value representation. No new fixture was
added; this package frontier had no approved standalone test, so the existing
cerealed bench remained the red signal.

Re-measure:

```text
bin/bench.sh -b interpreter --dub cerealed
skipping cerealed interpreter: pointer slice `[0..1]` exceeds allocated memory
  block `[0..0]`
```

The class-with-struct serialization/equality mismatch is gone. The next visible
interpreter blocker is the pre-existing pointer-slice-over-empty-allocation
class, now exposed as the first cerealed failure.

**2026-07-08 follow-up: pointer slices preserve backing allocation.** The
`pointer slice [0..1] exceeds allocated memory block [0..0]` frontier is
root-caused and fixed. No approved standalone fixture existed for this
package-only exposure, so the real-package bench remained the red signal. A
temporary unittest-result probe located the first failure at cerealed
`tests/classes.d:93` (`serialisation.via.base.class`), with a second matching
site at `tests/reset.d:9` (`reset.cerealiser`). A slice-expression probe showed
the failing read was `cast(ubyte*)(*this._data).arr[0 .. 1]` from
`std.array.Appender.data`.

The root was not a missing field write: a follow-up probe showed
`(*this._data).arr` assignments occurring throughout `Appender.put`. The lost
state was earlier, in `Appender.clear`, which assigns
`_data.arr = _data.arr.ptr[0 .. 0]`. The interpreter's `Value.pointerSlice`
rebuilt every pointer slice with `Value.arrayValue`, preserving the visible
slice elements but discarding the pointer target allocation and offset. The
empty array after `clear` therefore had length zero and no backing allocation,
so the next `put` could not grow from `arr.ptr[0 .. len + 1]` and `data`
tripped the stale empty-block bounds check.

`Value.pointerSlice` now returns an array view with the pointer target as its
allocation and the slice lower bound as its allocation offset. That keeps empty
pointer slices usable as zero-length views into existing storage, which matches
the `Appender.clear` contract and compiled D behavior.

Re-measure:

```text
bin/bench.sh -b interpreter --dub cerealed
skipping cerealed interpreter: Expression did not throw
```

The pointer-slice-over-empty-allocation frontier is gone. The next visible
interpreter blocker is a cerealed negative test whose expected exception is not
being thrown.

**2026-07-08 follow-up: lazy shouldThrow thunks execute generated wrappers.**
The `Expression did not throw` frontier is root-caused and fixed. No approved
standalone fixture existed for this package-only exposure, so the real-package
bench remained the red signal. A two-backend bench probe first located the
class across cerealed's negative tests (`decode.d`, `encode_decode.d`,
`enums.d`, `protocol_unit.d`, etc.); the first visible site was
`decode.d(8)`, `cereal.value!bool.shouldThrow!RangeError`.

Two temporary probes (reverted before commit) showed the decisive shape:
unit-threaded's lazy `expr` parameter captured DMD-generated zero-argument
function literals (`__dgliteral...`) for the UFCS negative checks. The previous
lazy-thunk support evaluated that literal expression as a value, so
`threw!T(expr)` observed a normal return instead of executing the wrapped
operation. The interpreter now invokes captured zero-formal function/delegate
literals in the saved lazy environment before falling back to direct expression
evaluation.

The same frontier also exposed that interpreter array bounds errors must be
catchable D exceptions, not host-only diagnostics: `grainRaw(length)` slices
`_bytes[0 .. length]`, while direct `grainUByte` uses `_bytes[0]`. The
interpreter now checks interpreted array slice/index bounds before the
unchecked value-layer access used by the benchmark build, and raises an
interpreted `core.exception.RangeError` with the existing diagnostic text.

Re-measure:

```text
bin/bench.sh -b interpreter --dub cerealed
skipping cerealed interpreter: Expected integer-compatible scalar.
```

A two-backend re-measure confirms the `Expression did not throw` class is gone.
The next visible interpreter blocker is `Expected integer-compatible scalar.`
The full mismatch list also shows deeper classes now exposed, including
`Unsupported cast to bool from Array` and existing property/underflow
families; the first single-backend frontier is the scalar-compatibility class.

**2026-07-08 follow-up: integer-compatible char and reinterpret loads.** The
`Expected integer-compatible scalar.` frontier is root-caused and advanced. No
new standalone fixture was added because this worker had no approval for one;
the existing cerealed bench remained the red signal. A two-backend bench probe
identified the scalar class at cerealed `tests/encode.d` and
`tests/encode_decode.d`: `encode.float`, `encode.double`, `encode.chars`, and
related encode/decode sites passed under `SystemLinker` and failed under
`Interpreter`.

The first root was that `Value.asLong` and
`Value.isIntegerCompatibleScalar` treated integral values and enums as
integer-compatible, but not D character scalars. The second root was
cerealed's `grainReinterpret`: it encodes floating-point values through
`*cast(uint*)(&floatValue)` and `*cast(ulong*)(&doubleValue)`. The interpreter's
local-pointer dereference returned the original `float`/`double` local even
after the pointer cast, so the downstream shift/mask path saw a floating
`Value` where D compiled code reads integer bits.

The interpreter now treats `char`/`wchar`/`dchar` as integer-compatible
scalars, and local-pointer loads through same-size floating-to-unsigned pointer
casts return the raw IEEE bits. Re-measure:

```text
bin/bench.sh -b interpreter --dub cerealed
skipping cerealed interpreter: Expression threw
```

A two-backend re-measure confirms the scalar class is gone. The next visible
interpreter blocker is `Expression threw` at the first remaining cerealed site,
`tests/encode.d:109` (`encode.chars`); deeper mismatches include existing
byte-encoding wrong answers, pointer/underflow families, and
`Unsupported cast to bool from Array`.

### 9.8 Rung 8 — real file IO (`std.stdio.File` create/write/read)

**Contract.** `File(path, "w")`, `f.write(...)`, scope-exit close via the
refcounted Impl, and `std.file.readText` agree with `SystemLinker`. Driven by
the user-visible fixture `rt/file.d` (`file.createWriteRead`), with the
per-root standalone fixtures `struct.voidInitialisedFieldSliceAssignment`
(ct/) and `strlen.localBuffer` (rt/cstdlib.d).

**Landed 2026-07-06.** The chain of roots this exposed, each fixed at its
seam:

```text
- slice assignment through a struct-field base (`s.buf[i .. j] = src[]`),
  the real error behind the §5-masked tempCString failure;
- pointer-typed integer constants (TempCStringBuffer.useStack's
  `cast(T*) size_t.max`) as native pointer values;
- `&field` of a static-array struct member as an array pointer;
- C strings marshalled from interpreter array pointers (fopen's path);
- delegating struct constructors (`this(...)` forwarding, File's ctor);
- native-memory struct loads/stores through the marshal layer
  (malloc'd Impl reads/writes; Tsarray fields for stat_t);
- struct out-parameters at flagged `&local` call sites (fstat);
- core.internal.atomic hooks (asm bodies interpreted as plain load/store/
  rmw; alignment asserts short-circuited) — File's refcount;
- `ref` writeback through `*pointer` arguments (core.atomic's shared
  overloads forward `*cast(T*)&val`) — the lost refcount store;
- postblit-call declaration initializers (`(copy = orig).__postblit()`)
  keeping the blitted variable, not the call's incidental result;
- pointer-into-array argument writeback for native calls that fill
  buffers (posix read);
- data-segment variables materializing their static initializers
  (std.encoding's bomTable, read by readText's BOM detection);
- char/integer code-point equality (bytes read from native memory
  compared through `cast(string)`).
- `&buf[i]` folded to SymOffExp: a pointer into the array's elements, not
  a scalar out-slot (the silent strlen-returns-0 bug).
```

The SystemLinker leg of the same fixture exposed that a Phobos template
instance first instantiated by another test's snippet is never emitted in a
later link; `adoptOrphans` in the native codegen (one adopt-then-prune pass,
replacing the ad-hoc `adoptTypeInfos`) re-homes out-of-link instances and
TypeInfos onto the rod, gated by the same provenance rules the prune uses.

### 9.9 Rung 9 — non-root module-scope variable initializers

**Contract.** Reading a module-scope variable of an imported (non-root)
module whose initializer references another symbol by name. Only root
modules get semantic2 (`parseRootModulesLocked`,
`source/quickbite/frontend/compiler.d`), so a Phobos module's
`ExpInitializer` can still be a bare, unresolved `IdentifierExp` when
the interpreter's dataseg materialization (impl.d ~1193, the §9.8
bomTable path) evaluates it — `runExpression` then falls through with
`Unsupported eval expression: identifier`. This is the module-variable
sibling of the on-demand-semantic3 finding documented at the top of
`tests/ut/backends/runner/ct/imports.d` for imported *function bodies*.

Concretely (triaged 2026-07-08, §7): std.internal.entropy's
`static EntropySource _entropySource = defaultEntropySource;`, where
`defaultEntropySource` is an enum introduced by the `entropyImpl` mixin
template instance. Reached by std.random's `unpredictableSeed`, i.e. by
every property-based cerealed test (unit_threaded `check!`) — 21
failures as of 2026-07-08. A sandbox import-path module does NOT
reproduce it: user imports are root-promoted and get semantic2, so the
exposing fixture must lean on a real archive (Phobos) module, like
§9.8's std.encoding fixture did.

**Fix direction.** Resolve the initializer before evaluating it — run
initializer/expression semantic in the variable's own module scope on
demand (the semantic2 analogue of the existing `functionSemantic3`
calls), rather than teaching `runExpression` to resolve raw
identifiers.

**Proposed exposing fixture (awaits approval; the unpredictableSeed
shape verified red on `Interpreter` at the exact entropy.d site, green
on `SystemLinker`, via standalone `bin/bench` repro 2026-07-08).** New
rt/random.d — rt/ because the green path reads the platform entropy
source (/dev/urandom via the §9.8 posix FFI machinery):

```d
unittest {
    import std.random: Random, uniform, unpredictableSeed;

    auto rng = Random(unpredictableSeed);
    const draw = uniform(0, 10, rng);
    assert(draw >= 0 && draw < 10);
}
```

Red today: `Unsupported eval expression: identifier`. The minimal core
is the `unpredictableSeed` read alone; the `Random`/`uniform` wrapper is
the user-visible headline and asserts a bounded draw on both backends.
If the wrapper drags in unrelated gaps at landing time, trim to the
seed read.

**Out of scope.** The entropy *call chain* past the initializer (open/
read of /dev/urandom) — that already routes through the existing FFI
path; if a deeper marshalling gap surfaces once the initializer
resolves, it is documented against `ffi.md`, not fixed here (seam-carve
lane owns `backends/ffi.d` and the marshalling files).

**Done (2026-07-08) — fix landed; Interpreter fixture blocked
downstream by an ffi.md gap.** `resolveNonRootInitializer` (impl.d, near
`runExpression`) runs `semantic2` on the dataseg variable in its own
module's global scope on demand — the semantic2 analogue of the
`functionSemantic3` calls that resolve imported function bodies — before
the dataseg materialization path (impl.d ~1196) evaluates its
initializer; `semantic2` may replace `variable._init`, so the caller
re-reads it. This resolves the non-root `IdentifierExp`: the
`Unsupported eval expression: identifier` error is **gone**.

The predicted deeper gap did surface exactly as the out-of-scope note
anticipated. On the standalone `unpredictableSeed` repro the Interpreter
leg now stops one step later, in the entropy read chain, with
`Expected pointer` — `getEntropy(&buffer, buffer.sizeof, …)` slices a
scalar local's address as a `void[]` byte buffer to be filled by the
`getrandom` syscall. That is a full FFI feature (scalar-local byte view +
`getrandom` fill + byte writeback), handed off to `ffi.md` §35.11, not
fixed here.

The exposing fixture landed as `rt/random.d`
`random.unpredictableSeedReadsNonRootInitializer` on the widest **green**
matrix — `SystemLinker` + `LLVMJit` — with `Interpreter` **omitted** per
§8 (the omission is the documentation; no pinned refusal), pending
`ffi.md` §35.11. `Ctfe` (no getrandom source) and `BytecodeNewCore` are
likewise omitted. The Rung 9 fix's own evidence is the standalone-repro
progression (`identifier` → `Expected pointer` at the identical entropy
site); the cerealed 21× `identifier` class converts to the same
getrandom FFI class rather than disappearing, so it is `ffi.md` §35.11
that finally clears it from the §7 inventory.

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
(`assumeSafeAppend`/`reserve`/capacity — already in cerealed's §7 inventory
via `gc_getArrayUsed`, so it lands before "beyond"), `ref ubyte[]` writeback
fidelity across the FFI marshalling seam, sourceless-Phobos coverage (routes
to `ffi.md`), and
captured/`scope`/`lazy` delegates (where a first-class delegate `Value` kind
meets `value.md`). Each gets its own rung under this plan when a real package
forces it — same loop: measure, distil, approve, red → green.

# Design: Interpreter — executing real project source

This is the **Interpreter language-completeness plan**. Its terminal goal: the
`Interpreter` backend executes the project source of a real dub package — every
statement and expression DMD hands it — so the package's unittests run under the
interpreter and agree, byte for byte, with the `SystemLinker` oracle. It is the
prerequisite no other plan owns.

This is the project's first priority. Cerealed is the driving integration
workload because it exercises a useful ordinary-D subset, not because the
Interpreter may know anything about that package. Production code must not
special-case Cerealed names, modules, paths, types, or behavior. Every failure
class becomes a standalone D semantic supported independently of the package.

The acceptance command is the default LDC-hosted benchmark:

```text
./bin/bench.sh -w 0 -r 1 -b interpreter --dub cerealed
```

A DMD-hosted run is a useful diagnostic control, but it is not the acceptance
or performance target: `bench.sh` uses LDC because DMD's optimiser makes the
benchmark result unrepresentative.

## 1. Goal

`Interpreter` executes the full statement/expression surface a real dub package
(driving fixture: **cerealed**) puts in front of it, so that
`runTests(Interpreter, modules)` produces the same per-unittest results as
`SystemLinker`. This includes reaching and correctly calling the body-less
native leaves encountered along the way. The Interpreter uses the typed-address
`quickbite.ffi.ffi` bridge; Interpreter-specific preparation,
callback re-entry, and exception translation stay in its backend adapter.
`quickbite.ffi.oldffi` remains only for Bytecode's parallel migration lane.

The unittest execution boundary returns success or a diagnostic directly. It
does not format the final interpreter result: display is a separate REPL
concern owned with `value.md`'s prelude formatter. Expressions and nested
function returns inside a unittest still produce interpreter-private runtime
results; separating the top-level contracts does not turn expression execution
into a `void` operation.

The empirical, external Cerealed gate is green on master: its whole unittest
suite runs on `Interpreter` in the default LDC host. The acceptance command is
now a standing regression gate while formatter migration and broader
Interpreter surface work continue.

**Ordering correction (2026-07-09).** The paragraph above holds only for
`value.md`'s *latency measurement*. Its representation *decision* is no longer
gated on this plan: PR #386's frontier work empirically confirmed the
correctness ceiling `value.md` (decision 2026-06-23) named as the decider, so
the dependency now runs the other way for one class of gaps — frontier failure
classes that are representation-induced defer to `value.md`'s native-layout
track instead of being shimmed here. See the triage rule in §8.

## 2. Non-goals

```text
- Bytecode's migration from `quickbite.ffi.oldffi` and deletion of that legacy
  package (`bytecode.md` and `ffi.md`);
- the Bytecode/IR backends' execution (ai/plans/bytecode.md);
- value representation choice (boxed vs native layout): ai/plans/value.md;
- new language features DMD does not lower for us (we execute DMD's AST, not
  raw source — templates and `static foreach` arrive pre-lowered);
- performance of the interpreter (correctness first; latency is `value.md`'s
  axis).
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
live in `tests/ut/backends/runner/lang/` (pure interpretation) and `sys/`
(runtime / FFI). This plan's fixtures are almost all `lang/` — they exercise
interpreter execution, not the native boundary.

## 4. Relationship to the FFI and representation plans

```text
quickbite.ffi.ffi
               address-only bridge shared by native-layout backends. It owns
               callable resolution, compiler-ABI provenance, CIF construction,
               and execution, but no backend value representation.
Interpreter adapter
               selects typed addresses and owns callback lifetime/re-entry and
               native exception translation. It has one preparation path and
               one execution path, with no legacy marshalling fallback.
value.md       how the interpreter represents runtime results and addressable
               storage. Assumes
               execution works; this plan delivers that assumption FOR THE
               LATENCY MEASUREMENT ONLY (corrected 2026-07-09). The meeting
               surface is wider than "a missing Value kind": any frontier
               class rooted in recursive aggregate boxing (synthetic
               pointers, cast-aliasing, allocation identity, reinterpret
               loads) is value.md's, handled per the §8 triage rule — red
               fixture here, Interpreter omitted, root fix there. The #386
               shims for such classes were a one-off exception (since
               retired), not precedent. value.md decisions 15-18 (2026-07-20)
               commit its end state (native-layout storage, a place is an
               address plus its static type, no FFI marshalling; deleting
               `Value` is the
               completion signal) and a two-track migration in which THIS
               plan is the workingness track and leads; the representation
               track lands in parallel behavior-neutral slices plus one
               small authority switch.
bytecode.md    a different backend; native-layout execution. Out of scope.
```

`LINK.d` alone does not identify a callable's ABI: DMD and LDC order explicit D
arguments differently. Every resolved callable carries the ABI of its defining
compiler; neither the bridge nor an adapter may hard-code DMD or LDC globally.
Bytecode owns the final `quickbite.ffi.oldffi` consumer and deletes that package
when its parallel address-only migration is complete.

Pointer slicing is ordinary D semantics and stays in this plan. Constructing
`ptr[lower .. upper]` creates a view at the adjusted address and length; it
must not eagerly read, unmarshal, or reconstruct the pointed-to elements.
It rejects `lower > upper` before address arithmetic, while deliberately not
checking whether the resulting view lies inside an allocation, matching
compiled D.

### 4.1 Standing work order

1. Keep the default LDC-hosted Cerealed acceptance command green.
2. Take the next confirmed omission from §9.11 or a newly measured package.
3. Distil it into a standalone, package-independent D behavior, then implement
   that behavior against `SystemLinker`.
4. Promote the fixture into its oracle matrix and re-run the Cerealed gate.

### 4.2 Unittest execution is not REPL evaluation

`TreeNodeBackend` has two entry points:

```text
executeUnitTest(UnitTestDeclaration) -> TestResult
evaluateRepl(FuncDeclaration)        -> EvalResult
```

The separation is the contract. A successful unittest reaches `TestResult`
without `displayString`, `Value.toString`, or `__quickbiteFormat`. A REPL
expression cell executes the frontend-synthesized formatter and returns its
string. Statement/no-display cells may use the same execution machinery
without manufacturing a display value.

Inside the walker, `runExpression` remains a recursive operation because all
real D code, including unittests, computes expressions and calls value-returning
functions. Its return type is not a public backend contract and need not remain
`quickbite.lang.Value`; per `value.md`, it becomes an interpreter-private
execution-result carrier containing only the immediate results, native handles,
locations, callables, and metadata the walker needs.

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
`tests/ut/backends/runner/lang/diagnostics.d` now executes
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
byte buffers), and already has a large `lang/cerealed.d` fixture to distil from.

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
`realloc.sliceAssignWritesNativeMemory` (sys/cstdlib),
`pointer.sliceAssignmentWritesArrayStorage` and
`pointer.indexAssignmentWritesVoidInitialisedArray` (lang/arrays). Audit
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
`pointer.refTernaryReturnLowersToAddressOfCall` (lang/expressions).
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
`refCall.assignmentToMemberRefReturnRunsCalleeBody` (lang/expressions;
BytecodeNewCore stays red and is omitted). automem re-measure: the 10×
`assignment target: call` mismatches **remain** — located diagnostics
show all ten are `fakePureErrno() = errnosave` (druntime
core/memory.d:1062/:1070), a **native** ref-returning body-less
function, i.e. a different root cause: the legacy `callViaLibffi` marshals the
return as
`type.next.toBasetype` and never consults `isref`, so a native ref
return's ABI pointer is read as if it were the value — the read at
memory.d:1060 yields the low bits of the errno address (a latent
silent-wrong-answer for pure reads), and assignment has no path at
all. Needs its own rung: ffi ref-return support (return the pointer,
deref for rvalue reads, write through it for assignment), sys/ exposing
fixtures against a body-less `ref`-returning libc accessor.

**2026-07-07 (bench-dub-corpus close-out).** `ai/plans/bench-dub-corpus.md`
is folded into its owning plans and deleted; the "item 3" / "follow-on"
citations above refer to that document's work items (PRs #352–#356 plus
the two rungs above), now git history. Its surviving content lands here,
in the legacy bridge's native-ref-return behavior, in `bench.md` (tardy
run-executor crash; `bin/bench` build
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
   48  pthread_mutexattr_init no available source     legacy FFI
   26  Unsupported eval expression: cast_             triage
   18  cannot read uninitialized variable
       `.trustedMoveImpl.result` in ctfe              triage
   10  Unsupported interpreter assignment target:
       call (all fakePureErrno)                       legacy FFI
    3  Unsupported eval call.                         Rung 6 family
    2  Unsupported eval statement: Error in
       test_allocator.TestAllocator.deallocate        NEW class, triage
    1  Unsupported eval expression: tuple             Rung 1 family
    1  Unsupported binary lhs type.                   triage
    1  false != true (silent)                         Rung 7 family
    1  Expected array. (new automem site)             triage

fearless  7/7 prepared, 8 mismatching tests — address of dotVariable
          GONE (cleared by PR #359):
    3  pthread_mutexattr_init no available source     legacy FFI
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

**2026-07-08 (post-#373 automem re-measure, master ce8b5851).** The legacy FFI
native-ref-return fix (PR #373) retires the 10×
`Unsupported interpreter assignment target: call` class; the same ten
tests now proceed deeper and fail as 10× `Expected struct.` — a NEW
automem class (Rung 2 was cerealed-scoped and closed; this is a fresh
site), needs triage and a standalone fixture per §8. automem total
unchanged at 111; all other classes byte-identical to the 2026-07-07
table above. `pthread_mutexattr_init` (48×, legacy FFI) remains
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
The `sys/concurrency.d` `thisTid` fixture currently lets the Interpreter
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
cerealed failure, but self-contained — so it lives in `lang/`, runs with no
package present, and stays meaningful long after cerealed changes. cerealed is
the *discovery* instrument (§6); the regression suite that proves each fix is
these independent fixtures, not the package.

```text
1. Phase 0 (§5) lands first so the real interpreter errors are visible at all.
2. For each reason in §7, write ONE standalone lang/ fixture (no cerealed
   dependency) reproducing that construct: green on SystemLinker (the oracle),
   red on Interpreter. Get it approved (AGENTS.md) before adding it. This is the
   red test that drives the rung.
3. Fix the ROOT until the fixture is green on Interpreter too. Then re-measure
   §6 and let the cerealed frequency table collapse.
4. A rung is "done" when: its standalone fixture passes on both backends, its
   class is gone from the cerealed §7 inventory, and lang/ and sys/ show no
   regression.
5. Re-run §6 between rungs: closing one class routinely reveals the next, deeper
   one previously hidden behind the first thrown error per unittest. Each newly
   revealed reason gets its own standalone red/green fixture in turn.
```

A single reason may need more than one fixture (e.g. read vs write, or per
element width), but each fixture still pins exactly one construct and obeys the
green-on-oracle / red-on-Interpreter rule. Fixtures follow the existing `lang/`
convention: a `static foreach (backend; AliasSeq!(Ctfe, Interpreter,
BytecodeNewCore, SystemLinker, LLVMJit))` matrix wrapping
`runBackendSourceFixtureTests!backend(q{ ... })` (see
`tests/ut/backends/runner/lang/cerealed.d` for the style — that file is itself
standalone distilled snippets, not a cerealed import).

**Matrix width and refusals (user guidance, 2026-07-07).** Each fixture runs
on the widest backend matrix it can express. A backend for which the fixture
stays red after the rung's fix is *omitted* from the fixture's backend
list — the omission is the documentation, now spelled
`Omit!(B, Because.refusal, "verbatim red")`
(`tests/ut/backends/package.d`). Do **not** pin a structured
unsupported diagnostic with `shouldThrowWithMessage`, especially for
backends still in development (`BytecodeNewCore`): such pins turn every
feature landing into a test-update chore, and per §7's
support-not-refusal directive a pinned refusal is never the end state.

**Triage rule: language-surface vs representation-ceiling (added
2026-07-09).** Before fixing a frontier class, classify its root:

```text
language-surface      the interpreter lacks a language behaviour any
                      representation needs (a missing expression branch,
                      lazy-parameter semantics, exception hierarchy,
                      on-demand semantic2). Fix here, red fixture first,
                      per the §8 loop.
representation-       the root is recursive aggregate boxing: synthetic
ceiling               (allocationId, offset) pointers instead of
                      addresses, cast-aliasing the value model cannot
                      see (`cast(S*) &chunk`), lost allocation identity,
                      reinterpret loads, or a runtime hook whose contract
                      is real memory (gc_*, memcpy). Write the standalone
                      red fixture (the durable asset), OMIT `Interpreter`
                      from its matrix per the rule above, and defer the
                      root to value.md's native-layout track. Do not add
                      a shim.
```

This does not contradict §7's support-not-refusal directive: support for
ceiling classes arrives via the representation change, not via name-based
shims that approximate it — a shim that skips construction semantics or
fabricates a hook's return value is a silent wrong answer, the worst class
in §7's own triage.

**Freeze corollary (2026-07-20, `value.md` decisions 17/18).** The same
gap-fixture-and-wait treatment applies to a class whose root fix needs new
boxed FFI marshalling (`ffi_marshal.d` rungs — new argument, out-parameter,
or struct shapes; e.g. the automem `pthread_mutexattr_init` class if it
needs one): the boxed marshaller is life support and receives no new shape.
The tie-breaker is decided — a blocked package
waits and re-earns its rows at the authority switch; do not re-decide it
mid-triage. Ordinary language-surface correctness fixes to boxed machinery
remain always in order: working first.

**Interception policy (added 2026-07-09).** Name-based interception of a
called function is reserved for functions the frontend has **no body** for
(`extern(C)` prototypes such as `memcpy` and the `gc_*` hooks — verify:
`fd.fbody is null` at the call site) or whose body is inline asm the
walker cannot execute (`core.internal.atomic`). A function with
interpretable D source must be executed; failure to execute it is an
interpreter or value-model gap to fix at the root, never to special-case.
`std.conv.text` is the one deliberate exemption (perf scaffolding, already
scheduled for removal by `value.md` remaining work item 1).

**Mechanical guard (landed, owed-fixtures follow-up).** The chokepoint is
`Walker.runCallExpression` (impl.d). Every name-based intercept there —
`tryInterpreterBuiltin`, `isDruntimeArrayOpAddAssign`, the `memcpy` name
check, `tryAssocArrayHook`, `tryAtomicHook`,
`isStringForeachApplyCall`, `isStdConvText`, and the raw-function-pointer
`enforceRawArraysConformableNogc` special case — now calls
`enforceInterceptionPolicy(callee, interceptorName)`
(`source/quickbite/backends/interpreter/interception_guard.d`) immediately
before running its handler. The guard's predicate,
`isLegalInterception`, accepts a callee when `fd.fbody is null`
(`hasNoAvailableSource`), or the body is/contains a `CompoundAsmStatement`
(a recursive walk using dmd's own `StatementRewriteWalker`, overriding
`visit(CompoundStatement)` — quickbite runs dmd frontend-only, so the
individual `AsmStatement`/`InlineAsmStatement` instructions inside an asm
block are never resolved past `null` placeholders; only the
`CompoundAsmStatement` wrapper node itself is reliably present, from parse
time onward), or the callee is on the exemption list below. Any other
body-ful, non-asm callee fails an `assert` naming the intercept and the
callee's `toPrettyChars` — deliberately an `AssertError`
(a `Throwable`, not `Exception`) rather than a thrown `Exception`, so it
cannot be swallowed by an interpreted `catch (Exception)` or by
unit-threaded's `shouldThrow`, and fails the enclosing unittest outright.
The check runs only on the already-rare path where some intercept has
matched, so it carries no hot-path cost worth gating behind `debug`.
Predicate unit tests live in
`tests/ut/backends/interpreter/interception_guard.d` (body-ful/non-exempt
rejected, body-less accepted, asm-bodied accepted, and the assert fires).

Exemption list (`isExemptInterception`), each with its retirement condition:

```text
std.conv.text                             §8's pre-existing deliberate
                                           exemption; retire per value.md
                                           remaining work item 1.
core.internal.array.operations.arrayOp!(  discovered by this guard, not
...)                                      previously in §9.10; retire with
                                           §9.10's native-layout-aggregates
                                           item.
core.internal.newaa._d_aa*!(...),         discovered by this guard, not
object.dup/keys/values!(...),             previously in §9.10; retire when
_d_aaApply2!(...)                         the AA representation moves to
                                           native layout (§9.10).
rt.aApply's _aApplycd1/_aApplywd1/        discovered by this guard, not
_aApplydc1/_aApplyRwd1                    previously in §9.10; extern(C)-
                                           mangled but D-bodied; retire when
                                           string/array native layout lands.
core.internal.util.array.                 discovered by this guard, not
enforceRawArraysConformableNogc           previously in §9.10; the worst of
                                           this batch — the shim fakes a
                                           `bool` return for a `void`-
                                           returning function. Retire by
                                           executing the real body once
                                           static-array element-wise ops are
                                           interpretable end-to-end.
core.atomic.atomicValueIsProperlyAligned  discovered by this guard, not
!(...) / atomicPtrIsProperlyAligned!(...) previously in §9.10; plain D bit
                                           arithmetic, no asm, despite living
                                           beside core.internal.atomic's real
                                           asm primitives. Retire once
                                           interpreter values carry real
                                           addresses (value.md native
                                           layout).
core.internal.atomic.atomicFetchSub!(...) discovered by this guard, not
/ atomicStore!(...)                       previously in §9.10; each forwards
                                           in one line to a sibling
                                           primitive (atomicFetchAdd /
                                           atomicExchange) that contains the
                                           real asm, so the asm-body check
                                           (which only inspects the callee's
                                           own body) misses them. Retire with
                                           the rest of the AtomicHook family.
tryInterpreterBuiltin's matched set:       discovered by this guard, not
std.math.algebraic.fabs/sqrt,             previously in §9.10; dmd's own
std.math.exponential.pow,                 `isBuiltin()` recognises these by
std.math.traits.isInfinity, and (via a    module+identifier for its CTFE
bare-identifier fallback with no          builtin table regardless of body,
`BUILTIN` entry) std.math.traits.signbit  so quickbite's reuse of that table
                                           inherits the same body-
                                           independence. The `signbit`
                                           fallback is also an unreported
                                           latent bug in its own right (no
                                           module check, so it would misfire
                                           on an unrelated user `signbit`).
                                           Retire once `InterpreterBuiltin`
                                           computes each from the value's
                                           real representation in a native-
                                           layout world.
```

Every entry above except `emplaceRef` and `std.conv.text` was unknown before
this guard existed — the guard's own construction is what surfaced them,
exactly per §8's intent: the list is finite, visible, and shrinks, rather
than growing silent shims. None of them changed behaviour; the guard adds
enforcement and an explicit inventory only.

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
fixtures landed in lang/structs.d — the headline
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
2026-07-08).** lang/arrays.d, pointer.* family:

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
`pointer.emptySliceAssignmentThroughNullPointerIsNoOp` (lang/arrays.d,
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
the dispatcher misses, or a native leaf that should route to the legacy bridge
while it remains — the latter is not a language-surface workaround.

**2026-07-08 follow-up: lazy assertion thunks.** After the GC array-capacity
hook slice, the package re-measure discovered:

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

Handoff: add a standalone fixture for this before the next implementation
change. The interrupted worker drafted
`lazyForwardedAssertionThunkRunsExpression`; reconstruct the red-first proof by
applying only that fixture on the parent of `7f09bd67` and running it against
`SystemLinker` and `Interpreter`. The expected red is `Interpreter` failing
with `Unsupported eval call.` Then add the fixture on this PR branch, where
the existing lazy-parameter implementation should make it green.

The interpreter now records lazy formal parameters as expression thunks with a
captured local snapshot, preserves that thunk when a lazy parameter is
forwarded to another lazy parameter, and evaluates the thunk when the
zero-argument lazy parameter is called.

Re-measure: the `Unsupported eval call.` frontier is gone. The package advances
to the pre-existing corrupted/garbage failure-message class tracked under Rung
7; this is the next visible interpreter blocker.

**Done.** Each site either interprets or is a native-boundary case.

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
then `"hellobettyeven more"`). The package re-measure discovered the missing
memory-copy/pointer-snapshot behaviour. Handoff: verify that the existing
`array.newSliceMemcopiesStructElements` and
`struct.sliceAssignmentViaEscapedPointerWritesBack` fixtures were red-first for
this exact support gap. If not, add the missing standalone fixture by applying
only the test on the pre-fix parent, proving it red there, and then carrying it
forward green on this PR branch. `memcpy` now copies scalar elements into
native destinations from the typed source pointer behind `void*` casts, and
pointer index/slice assignment falls back to updating the pointer target
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
frontier. The package re-measure exposed the dynamic-array-capacity lowering
gap:
`bin/bench.sh -b interpreter --dub cerealed` skipped with:

```text
`gc_getArrayUsed` cannot be interpreted at compile time, because it has no
available source code
```

Handoff: add a standalone fixture for this before changing the implementation
further. The interrupted worker drafted
`gcReserveArrayCapacityHookReturnsRequestedBytes`; reconstruct the red-first
proof by applying only that fixture on the parent of `ee3594a9` and running it
against `SystemLinker` and `Interpreter`. The expected red is `Interpreter`
failing with `` `gc_reserveArrayCapacity` cannot be interpreted at compile
time, because it has no available source code``. Then add the fixture on this
PR branch, where the existing GC hook implementation should make it green.

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
the lazy assertion thunk slice, the package re-measure discovered:

```text
bin/bench.sh -b interpreter --dub cerealed
skipping cerealed interpreter: <127 bytes of 0xff rendered as garbage>
```

Handoff: add a standalone fixture for this before changing the implementation
further. The interrupted worker drafted `emplaceRefWritesArrayElement`;
reconstruct the red-first proof by applying only that fixture on the parent of
`bce523cc` and running it against `SystemLinker` and `Interpreter`. The
expected red is `Interpreter` failing in the `emplaceRef`/trusted-move path,
for example with `cannot read uninitialized variable .trustedMoveImpl.result
in ctfe`. Then add the fixture on this PR branch, where the existing
`emplaceRef` hook should make it green. A probe on `InterpretedException`
showed the failing `UnitTestException.msg` had the correct length but every
element was `char.init` (`0xff`). The first failing site was cerealed
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
a temporary full-message package probe:

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
field mutation with the existing value representation. Handoff: add a
standalone fixture for this aliasing gap. The interrupted worker drafted
`classReferencePassedByValueMutatesObject`; reconstruct the red-first proof by
applying only that fixture on the parent of `ca901fd9` and running it against
`SystemLinker` and `Interpreter`. The expected red is `Interpreter` observing
the default field value instead of the callee's mutation. Then add the fixture
on this PR branch, where the existing writeback should make it green.

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
root-caused and fixed. The package re-measure exposed the pointer-slice
allocation gap. Handoff: add a standalone fixture for this. The interrupted
worker drafted `appenderClearKeepsPointerSliceBackingAllocation`; reconstruct
the red-first proof by applying only that fixture on the parent of `833c560c`
and running it against `SystemLinker` and `Interpreter`. The expected red is
`Interpreter` failing with `pointer slice [0..1] exceeds allocated memory
block [0..0]`. Then add the fixture on this PR branch, where the existing
pointer-slice allocation preservation should make it green. A temporary
unittest-result probe located the first failure at cerealed
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
The `Expression did not throw` frontier is root-caused and fixed. A two-backend
package probe first located the class across cerealed's negative tests
(`decode.d`, `encode_decode.d`, `enums.d`, `protocol_unit.d`, etc.); the first
visible site was `decode.d(8)`,
`cereal.value!bool.shouldThrow!RangeError`.

Handoff: the generated-wrapper path can share the
`lazyForwardedAssertionThunkRunsExpression` fixture from Rung 6, but the later
state-propagation part needs its own standalone fixture. The interrupted worker
drafted `decodeLazyForwardedRangeErrorSeesReaderState`; prove it red on the
pre-fix state by applying only the fixture before the lazy-capture writeback
change, then carry it forward green with the implementation.

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
`Expected integer-compatible scalar.` frontier is root-caused and advanced. A
two-backend package probe identified the scalar class at cerealed
`tests/encode.d` and
`tests/encode_decode.d`: `encode.float`, `encode.double`, `encode.chars`, and
related encode/decode sites passed under `SystemLinker` and failed under
`Interpreter`.

Handoff: this frontier still needs standalone red-first fixtures. Split it by
root cause: one fixture for character scalar values being integer-compatible,
and one for floating-pointer bit reinterpret loads such as
`*cast(uint*)(&float)` and `*cast(ulong*)(&double)`. Prove each fixture red on
the parent of `82297fe9`, then carry it forward green on this PR branch. The
PR review also asked whether the floating-bit helper belongs outside the
interpreter; use these fixtures to drive the shared placement if another
backend needs the same behaviour.

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

**2026-07-08 follow-up: native `RangeError` is an `Error`, not an
`Exception`.** The generic `Expression threw` frontier is root-caused and
advanced. Handoff: verify that the existing
`exception.errorIsNotCaughtByExceptionHandler.Interpreter` fixture is a
red-first proof for this exact native `RangeError` catch-classification gap.
If it is not, add a narrow standalone fixture and prove it red on the parent of
`aa1f4796`, then carry it forward green. The PR review also called out the
name-based `Error`/`Exception` classification; the next implementation pass
should prefer frontend/type information if it is available. A temporary
two-backend location probe corrected the visible site: the current
`__unittest_L109_C1` failure is `tests/decode.d:109` (`decode.chars`), not
`tests/encode.d:109`; the earlier location was stale after intervening
frontier movement.

Temporary throw/catch probes showed the original exception was the
interpreter's synthetic `core.exception.RangeError` from
`cerealed.decerealiser.Decerealiser.grainUByte`
(`index [0] is out of bounds for array of length 0`). Unit-threaded's outer
`shouldNotThrow` caught it as `object.Exception` and rethrew the unhelpful
`UnitTestException("Expression threw")`. That catch is wrong for compiled D:
`RangeError` derives from `Error`, not `Exception`.

The fallback native-exception type-name synthesis now classifies
`core.exception.*Error` / `object.*Error` as `Error` hierarchies while keeping
other native exceptions under `Exception`. Re-measure:

```text
bin/bench.sh -b interpreter --dub cerealed
skipping cerealed interpreter: index [0] is out of bounds for array of length 0
```

The two-backend mismatch list confirms `Expression threw` is gone. The next
visible interpreter blocker is the now-unmasked `RangeError` at
`tests/decode.d:109` (`decode.chars`): the expected final
`value!ubyte.shouldThrow!RangeError` still escapes as an uncaught
`RangeError`.

**2026-07-08 follow-up: `decode.d:109` RangeError-catching probe.** A
temporary location probe corrected the visible label: the first failing
`__unittest_L109_C1` is `decode.d:109`, the `decode.double` unittest, not
`decode.chars` (that unittest starts at line 116 in the checked-out cerealed
source).

Temporary probes (reverted before commit) showed:

```text
bin/bench.sh -b interpreter --dub cerealed
QB_SHOULD_THROW e1=variable arg0=function_ lazy0=true args=3 params=3
QB_CATCH_RANGE ... has=true
QB_TOP loc=decode.d(109) msg=index [0] is out of bounds for array of length 0
```

The `shouldThrow` call shape is already a plain function call whose argument
0 is a DMD-generated lazy wrapper (`FuncExp`) and whose first formal is
recognized as `lazy`. `catch(RangeError)` also matches the synthetic
`core.exception.RangeError` object (`has=true`) in the same run, so Worker 9's
exception hierarchy fix is not the remaining blocker.

A filtered `grainUByte` receiver probe for the exact `decode.double` byte
pattern showed the first two `shouldNotThrow(cereal.value!double)` calls
consume all 16 bytes successfully; the next read then sees
`Decerealiser([], [], 0, 0)` and throws the raw RangeError before the unittest
is reported green. The evidence pointed at lazy forwarding/state around the
generated function-literal wrapper used by unit-threaded's
`shouldNotThrow`/`shouldThrow`, not at catch matching.

**2026-07-09 handoff: red-first reconstruction for missing fixtures.** The
correct next step is not to treat the package bench as the red test. Because
this PR already contains several fixes, a new fixture will often pass on the
current PR head. Reconstruct the red state instead:

```text
1. For a gap fixed by commit X, create a temporary worktree at X^.
2. Add only the minimal regression fixture there.
3. Run the focused fixture against SystemLinker and Interpreter.
4. Record SystemLinker green and Interpreter red, including the exact failure.
5. Add the same fixture on this PR branch.
6. Keep or adjust the implementation so the focused fixture, ninja bin/ut, and
   bin/ut --random are green.
7. Commit the fixture, any implementation correction, and this plan update
   together.
```

If the fix boundary spans multiple commits, use the parent of the first commit
that made the behaviour pass. If that boundary is unclear, use a temporary
revert in a throwaway worktree to prove the fixture fails without the fix, then
restore the fix on this branch.

The interrupted worker left uncommitted draft work in this worktree for the
next agent to inspect, not as completed work:

- `tests/ut/backends/runner/lang/cerealed.d` draft fixtures:
  `lazyForwardedAssertionThunkRunsExpression`,
  `gcReserveArrayCapacityHookReturnsRequestedBytes`,
  `emplaceRefWritesArrayElement`,
  `classReferencePassedByValueMutatesObject`,
  `appenderClearKeepsPointerSliceBackingAllocation`, and
  `decodeLazyForwardedRangeErrorSeesReaderState`.
- `source/quickbite/backends/interpreter/impl.d` draft implementation for lazy
  captured-local writeback, intended for the `decode.d:109` frontier.
- `source/quickbite/backends/interpreter/builtins.d` draft cleanup for the
  `GCArrayHook` lookup review comment.

These drafts need review and real red-first proof before they are committed.
Do not present them as completed fixtures until the focused red and green
commands have been run and recorded.

**2026-07-13 (size_t underflow rung, partial close).** Re-triaged the 6
`index [18446744073709551615 / 0] out of bounds` cerealed mismatches
(`bin/bench.sh -b interpreter -b system-linker --dub cerealed`, with a
throwaway `failure.location` probe in `testResultsMismatches` to locate
each by file/line, reverted before commit): `pointers.d(82)`,
`protocol_unit.d(114)`/`(151)`/`(169)`, `static_array.d(27)`,
`structs.d(184)`. The last two share one root, now fixed:
`Walker.runIndexExpression` (impl.d, `arr[e2]` handling) evaluated
`index.e2` — which can reference `$` bound to `index.lengthVar` — *before*
running `index.e1` and seeding `lengthVar` from its length, so
`arr[$ - 1]` right after growing `arr` read a stale or default-zero `$`
and underflowed to `size_t.max`. `runSliceExpression` already runs `e1`
and seeds `lengthVar` before its bounds check, so `runIndexExpression`
now matches that order. Exposing fixture
`dynamicArray.dollarReflectsLengthAfterInPlaceGrowth`
(`tests/ut/backends/runner/lang/arrays.d`), modelled on cerealed's
`val.length++; cereal.grain(val[$ - 1])` decode loop (grainRawArray /
grainWithLengthInBytesAttr in cereal.d): red on `Interpreter` (`array
index 18446744073709551615 is out of bounds` before the fix), green on
`Ctfe`, `SystemLinker`, `LLVMJit` throughout; `Bytecode` omitted
(`Unsupported variable in bytecode core: $`, not implemented there).
Re-measure: `static_array.d(27)` and `structs.d(184)` are gone from the
cerealed mismatch list; both go through `grainRawArray`'s direct
`val[$-1]`.

The `protocol_unit.d` trio and `pointers.d(82)` remain red — **not** the
same root. A probe fixture (`void grow(ref Holder val) { val.arr.length
++; }`) reproduces a silent wrong answer with no `$` involved at all:
mutating an array-typed field through a `ref` struct parameter
(`__traits(getMember, val, member).length++`, exactly
`grainWithLengthInBytesAttr`'s shape, `val: ref T`) does not persist
back to the caller — `h.arr.length` reads `0` after `growLast(h)`
returns. That silent loss is why the three `protocol_unit.d`
`@LengthInBytes` tests still underflow `$` afterwards: the array never
actually grows from the caller's perspective, so `$` (now correctly
computed) is legitimately `0` even after the interpreted `length++`.
This is a distinct rung-7 root (ref-parameter struct-field array
mutation, not the `$`/`lengthVar` ordering bug) and needs its own
standalone exposing fixture and fix; not attempted here per the "prefer
one clean root" guidance. `pointers.d(82)`'s `index [0] is out of
bounds for array of length 0` is a deliberate `dec.value!ubyte
.shouldThrow!RangeError` (compiled D throws on purpose); Interpreter
fails the same way `decode.d:109` did before the 2026-07-08 native-
`RangeError`-is-an-`Error` fix — still unexplained here, needs its own
triage. Net: 2 of the 6 cerealed failures in this class close; 4 remain
(3 ref-struct-field-mutation, 1 unclassified `shouldThrow!RangeError`
miss), tracked here for follow-up.

**2026-07-13 (ref-struct-array-field-mutation root, partial close).**
Root-caused the ref-parameter struct-field array mutation gap from the
follow-up above. Reproduced `void grow(ref Holder val) { val.arr.
length++; }` under a temporary `stderr` trace of `Walker.
runDeclarationExpression`/`runLoweredAssignExpression`/
`writeBackRefArguments` (reverted before commit): dmd lowers postfix
`h.arr.length++` (unlike plain `h.arr.length = h.arr.length + 1`, which
stays a `LoweredAssignExp` whose `e1` is the `h.arr` `ArrayLengthExp`
directly) through a synthetic `ref` local bound to the field, e.g.
`(ref int[] __arraylength3 = h.arr;) , _d_arraysetlengthT(
__arraylength3, __arraylength3.length + 1LU)`. The interpreter's
`recordStructFieldAlias` correctly records `__arraylength3` as an alias
of `h`'s `arr` field (confirmed live via the trace). The break was in
`Walker.runLoweredAssignExpression` (impl.d): once `assign.e1.
isArrayLengthExp.e1` resolves to a plain `VarExp` (`__arraylength3`,
not a `DotVarExp` like `h.arr`), the function took a "fast path" that
wrote the grown array straight into `locals[variable]` and only cleared
`uninitializedLocals`/`sliceAliases` — bypassing `writeLocation`
entirely, so `writeThroughStructFieldAlias` (and
`writeThroughArrayElementAlias`) never ran and the growth never
reached `h`. The `DotVarExp` fallback branch (`var is null`) already
went through `writeArrayLengthLocation` → `writeLocation`, which is why
plain `h.arr.length = h.arr.length + 1` worked before this fix while
`h.arr.length++` did not.

Fix: replace the direct `locals[variable] = Value.arrayValue(elements)`
write with `writeLocation(var, Value.arrayValue(elements))`, so the
`VarExp` alias-target case runs through the same single write-location
authority as every other assignment, including
`writeThroughStructFieldAlias`.

The alias write must refresh any promoted native struct cell from the rebuilt
owner, not only its scalar fields. Once promoted, that cell is authoritative
for reads; leaving a dynamic-array field's slice header stale would overwrite
the correct boxed growth with the old length on the next field read.

Exposing fixture
`struct.postfixLengthIncrementGrowsRefParamArrayField`
(`tests/ut/backends/runner/lang/structs.d`): a `Holder { int[] arr; }`,
`ref Holder` parameter, `h.arr.length++` then `h.arr[h.arr.length - 1]
= 7` (deliberately `$`-free — see below), asserting the caller's `h`
sees both the grown length and the written element after the call
returns. Confirmed red on `Interpreter` (`index
[18446744073709551615] is out of bounds for array of length 0`,
i.e. the growth silently never happened) on the pre-fix parent,
green on `Ctfe`/`SystemLinker`/`LLVMJit` throughout; `Bytecode`
omitted (still red, under active development, existing omit-don't-pin
rule).

This fixture is deliberately kept `$`-free. Probing `h.arr[$ - 1] = 7`
after `h.arr.length++` (or even after the already-working `h.arr.
length = h.arr.length + 1`) still underflows on `Interpreter`: that is
a **third**, still-separate root — `Walker.runIndexAssignExpression`'s
`DotVarExp` branch (the `arr[i] = v` assignment-target path for an
array-typed struct field) evaluates `index.e2` (`$ - 1`) before running
`index.e1`/seeding `index.lengthVar`, the same class of bug already
fixed for the *read* path (`runIndexExpression`, this rung's earlier
2026-07-13 entry) but never applied to this assignment-target branch.
Not fixed here, to keep this commit to the one root its test pins.

Net effect on the `protocol_unit.d` trio (`__unittest_L114/151/169`):
this fix closes the size_t-underflow **crash** (`index
[18446744073709551615] is out of bounds`) that was masking their real
comparison. Re-measuring `bin/bench.sh -b interpreter -b system-linker
--dub cerealed` with only this fix applied shows all three now fail as
plain value mismatches instead (`Expected: 3` / `Expected: 1` /
`Expected: Struct(...)`), still red against `SystemLinker`. cerealed's
actual `grainWithLengthInBytesAttr` body is `__traits(getMember, val,
member).length++; cereal.grain(__traits(getMember, val, member)[$ -
1]);` — the decoded element is written through a `ref int` **call
argument** that is an `IndexExp` (`arr[$ - 1]`), not a direct
assignment. A fourth probe,
`struct.probeGrowArrayFieldThenPassLastElementByRef` (not committed,
scratch-only), confirms this is its own gap: `Walker.
isWritableLocation` does not include `IndexExp`, so `Walker.
writeBackRefArguments` silently skips writing back a `ref` parameter
whose caller-side argument expression is an index into an array — the
decoded value never lands in the caller's array element. So the
`protocol_unit.d` trio needs a fourth root (ref-argument array-element
write-back) fixed before it turns green; this fix and its test close
the crash but not the trio itself. `pointers.d(82)` is unaffected by
any of this — same `index [0] is out of bounds for array of length 0`
`shouldThrow!RangeError` miss as before, still needing its own,
unrelated triage.

**2026-07-13 (index-assign `$`-ordering root, closed).** Fixed the third
root named just above: `Walker.runIndexAssignExpression`'s `DotVarExp`
branch (impl.d, the `h.arr[i] = v` assignment-target path for an
array-typed struct field) evaluated `index.e2` (which can reference `$`
bound to `index.lengthVar`) and computed the receiver/field *before*
seeding `lengthVar` from the field's actual length — the write-path twin
of the read-path bug this rung's earlier 2026-07-13 entry fixed in
`runIndexExpression`. `h.arr[$ - 1] = v` right after growing `h.arr`
underflowed `$` to `size_t.max`. Fix: resolve the field, seed
`lengthVar` from the field array's length, then evaluate `index.e2`,
mirroring the read path's order.

Exposing fixture
`struct.dollarInIndexAssignReflectsFieldLengthAfterGrowth`
(`tests/ut/backends/runner/lang/structs.d`): `Holder { int[] arr; }`, a
`ref Holder` parameter grows the field with plain `h.arr.length = 3`
(not postfix `++`, to keep this pinned to the index-assign root and not
the already-fixed postfix-length-increment one) then writes
`h.arr[$ - 1] = 9`. Confirmed red on `Interpreter` (`index
[18446744073709551615] is out of bounds for array of length 3`),
green on `Ctfe`/`SystemLinker`/`LLVMJit` throughout; `Bytecode` omitted
(`$` unimplemented there, per §8's omit-don't-pin rule).

cerealed impact: `bin/bench.sh -b interpreter -b system-linker --dub
cerealed` still shows the `protocol_unit.d` trio
(`__unittest_L114/151/169`) as plain value mismatches (`Expected: 3` /
`Expected: 1` / `Expected: Struct(...)`), unchanged from before this
fix. That trio's actual cerealed code
(`cereal.grain(__traits(getMember, val, member)[$ - 1])`) reads the
grown element through a `ref` **call argument** that is an `IndexExp`,
not a direct index-assignment, so it never reaches the `DotVarExp`
branch fixed here — it needs the fourth root already named above
(ref-argument array-element write-back, `Walker.isWritableLocation`/
`writeBackRefArguments` not handling an `IndexExp` argument). That root
remains open; this fix closes a distinct, real bug but does not turn
the trio green.

**2026-07-13 (ref-argument array-element write-back root, closed).**
Fixed the fourth root named just above: `Walker.isWritableLocation`
(impl.d) did not recognize an `IndexExp` (an array element, e.g.
`arr[i]` or `arr[$ - 1]`) as a writable location, so
`writeBackRefArguments` silently skipped writing a `ref` parameter's
final value back into the caller's array element whenever the call
argument was an index expression — exactly cerealed's
`grainWithLengthInBytesAttr` shape, `cereal.grain(__traits(getMember,
val, member)[$ - 1])`, where `grain` takes `ref T`. Fix: add
`expression.isIndexExp !is null` to `isWritableLocation`'s accepted
kinds. `writeBackRefArguments` already called the general
`writeLocation`, which already dispatches an `IndexExp` target to the
existing `writeIndexLocation` (both the plain-`VarExp`-array and
`DotVarExp`-array-field branches); only the `isWritableLocation` gate
was blocking the call, so no other write-path code changed. The same
gate is shared by `writeBackThis`, `writeBackByValueClassArguments`,
and `writeBackByValueStructArguments`, so an indexed receiver/argument
for those write-back paths is now handled too, for free, by the same
single-authority mechanism.

Exposing fixture `dynamicArray.refParamWriteBackThroughIndexArgument`
(`tests/ut/backends/runner/lang/arrays.d`): `void setTo(ref int x, int
v) { x = v; }` called as `setTo(arr[1], 7)`, asserting the caller's
`arr[1] == 7` afterwards. Confirmed red on `Interpreter` (`0 != 7`,
i.e. the write silently never happened) before this fix, green on
`Ctfe`/`SystemLinker`/`LLVMJit` throughout; `Bytecode` omitted
(`Unsupported ref argument in bytecode core: arr[1]`, not implemented
there, per §8's omit-don't-pin rule).

cerealed impact: `bin/bench.sh -b interpreter -b system-linker --dub
cerealed` re-measured before/after this fix (same worktree, fix
stashed/popped to compare). Before: the `protocol_unit.d` trio
(`__unittest_L114/151/169`) shows as value mismatches (`Expected: 3` /
`Expected: 1` / `Expected: Struct(...)`). After: all three lines are
gone from the interpreter/system-linker disagreement list entirely —
the trio is now **green**, closing the `protocol_unit` root chain
opened by this rung's earlier 2026-07-13 entries (`$`/`lengthVar`
ordering on both the read and index-assign paths, plus this
ref-argument write-back gap). `pointers.d(82)` is unaffected — same
`index [0] is out of bounds for array of length 0`
`shouldThrow!RangeError` miss as before, still needing its own,
unrelated triage.

**2026-07-13 (void-init `ref`-argument read, `.grain.b` root closed).**
Root-caused the 3× `cannot read uninitialized variable \`.grain.b\` in
ctfe` class. Not a struct-field-read bug as first guessed from the
message shape (`.<function>.<var>`): cerealed's `cereal.d` `grain(U, C,
T)` (the `isOutputRange!(T, ubyte)` overload) declares `ubyte b =
void;` then calls `cereal.grain(b);`, a **plain local**, written only
through two nested `ref`-parameter-forwarding calls (`grain(ref ubyte
val) { writeByte(val); }`) before the caller reads `b` back. Root:
`Walker.runCallExpression`'s argument-evaluation loop (impl.d, the
`Value[] arguments` build) called `runExpression(argument)` for every
argument unconditionally, including `ref` parameters — but compiled D
never reads through a `ref` binding at the call site, it only takes the
address. Reading a still-void local eagerly here hit the existing
uninitialized-read guard and threw, even though the callee was about to
write it, not read it. Fix: a new `runRefArgumentExpression` (impl.d,
directly after `runCallExpression`) used for `ref` parameters — returns
`Value.void_` without reading when the argument is a `VarExp` whose
variable is still in `uninitializedLocals`, otherwise defers to the
normal `runExpression`; `writeBackRefArguments` (already existing)
overwrites the placeholder with whatever the callee wrote once the call
returns, restoring the caller-visible value and clearing
`uninitializedLocals` through the existing `writeLocation` path.

Exposing fixture `refArgument.voidLocalIsReadableAfterNestedRefWrite`
(`tests/ut/backends/runner/lang/structs.d`): `void writeByte(ref ubyte
val) { val = 42; }`, `void grain(ref ubyte val) { writeByte(val); }`,
`ubyte readGrain() { ubyte b = void; grain(b); return b; }`, asserting
`readGrain() == 42`. Confirmed red on `Interpreter` (`cannot read
uninitialized variable \`.readGrain.b\` in ctfe`) before this fix, green
on `Ctfe`, `Bytecode`, `SystemLinker`, and `LLVMJit` throughout — full
matrix, nothing omitted.

cerealed impact: `bin/bench.sh -b system-linker -b interpreter --dub
cerealed` re-measured before/after. Before: 16 disagreements, including
all 3 `.grain.b` sites (`range.d` lines 31/42/92, the `output.range.*`
and `embedded.output.range` tests — `grain.d` in the task description
was the enclosing function's name, not a file). After: all 3 are gone;
the tests advance past `grain`/`writeByte` into two new, deeper frontier
classes uncovered by removing this blocker — `Expected struct.`
(`classes.d`) and `Expected array.` (`decode.d`) — both new triage
items, not regressions. Net: 16 → 15 disagreements (3 closed, 2 newly
exposed by advancing further).

**2026-07-13 (foreach-ref-over-struct-field-array root, closed).**
Re-measured `bin/bench.sh -b interpreter -b system-linker --dub cerealed`
(HEAD `e3f7486f`): 15 mismatches, unchanged in shape from the table above
except the `.grain.b` class is gone (closed by the entry just above) and
two new frontier classes are visible one level deeper: `Expected struct.`
(`decode.d:262`, an enum-in-struct `shouldThrow` case) and `Expected
array.` (`static_array.d:7`) — both untriaged, tracked below, not fixed
here.

Picked the highest-leverage remaining class: `protocol_unit.d`'s
`__unittest_L24`/`__unittest_L58` (`pkt.units[1].us.shouldEqual(6)` /
`pkt.units[2].us.shouldEqual(5)`), both `Expected: N / Got: 0` — a
silent-wrong-answer, the most urgent §7 category, and the array length
itself (`pkt.units.length`) was already correct, narrowing the fault to
element writes. cerealed's `@ArrayLength` field decode
(`grainWithArrayLengthAttr` in cereal.d) is `member.length = length;
foreach (ref e; member) cereal.grain(e);` where `member` is `val.units`,
a dynamic-array **field** of a `ref Packet val` parameter, and `grain(e)`
writes `e`'s scalar fields through further nested `ref` forwarding.

Root: dmd's own foreach-to-for lowering (`statementsem.d`) rewrites
`foreach (ref e; val.units)` into `T[] __r = val.units[]; for (size_t
__k = 0; __k < __r.length; ++__k) { ref Unit e = __r[__k]; ... }` — a
hidden slice-typed temporary `__r` aliases the field array, and `e`
aliases an element of `__r`. `Walker.recordSliceAlias` (impl.d) recorded
`__r` as a slice alias only when the sliced expression (`slice.e1`) was
a plain local `VarExp`; a `DotVarExp` aggregate (`val.units`, a struct
field) fell through to `sliceAliases.remove(variable)`, leaving `__r`
untracked. `Walker.writeThroughArrayElementAlias` already cascades an
element write into `writeThroughSliceAlias` when the array variable
(`__r`) has a recorded slice alias — but with none recorded, writes to
`e`'s fields updated only the interpreter's local snapshot of `__r`,
never `val.units`, so the caller's array element silently kept its
default (`0`) value. Fix: `recordSliceAlias` gains a `DotVarExp` branch
(mirroring `recordStructFieldAlias`'s existing one) that resolves the
field's owner and index and records them on `SliceAlias` (two new
fields, `hasFieldIndex`/`fieldIndex`); `writeThroughSliceAlias` rebuilds
`val.units` via `structFieldAt`/`withStructField` when set, instead of
treating `__r`'s source as a whole array local.

Exposing fixture `struct.foreachRefOverFieldArrayPersistsElementWrites`
(`tests/ut/backends/runner/lang/structs.d`): a `Container { Item[] items;
}`, a `ref Container` parameter grows `items` then `foreach (ref item;
container.items)` calls a helper writing `item`'s fields through one more
`ref`-forwarding layer, asserting the caller sees both elements' fields
afterward. Confirmed red on `Interpreter` (`0 != 6`) before this fix,
green on `Ctfe`, `SystemLinker`, `LLVMJit` throughout; `Bytecode` omitted
(segfaults on this fixture, under active development, §8's omit-don't-pin
rule).

cerealed impact: re-measured before/after with the same worktree (fix
stashed/popped). Before: 15 mismatches, including `protocol_unit.d`'s
`__unittest_L24`/`__unittest_L58`. After: both are gone; cerealed drops to
13 mismatches with no newly-unmasked classes — the tests fully agree with
`SystemLinker` past this point. The `decode.d`/`static_array.d` classes
from the re-measure above remain open and untriaged.

**2026-07-14 (struct-identity enum-field root, closed).** Re-measured the
13 remaining cerealed mismatches (`bin/bench.sh -b interpreter -b
system-linker --dub cerealed`, HEAD `ccf34201`, with a throwaway
`failure.location`-and-full-`message` probe in `testResultsMismatches`,
reverted before commit) and triaged the two silent-wrong-answer structs.d
sites (`__unittest_L146`, the `EnumStruct` roundtrip, and `__unittest_L298`,
the `MqttFixedHeader` roundtrip): both showed the decoded enum field
displayed as a bare number (`EnumStruct(1, 2)`, `MqttFixedHeader(3, ...)`)
instead of its member name, alongside the same underlying numeric value
`SystemLinker` produced. Bisecting via standalone probes (a hand-rolled
`grain`/`FakeDecerealiser` matching `cerealed/src/cerealed/cereal.d`'s enum
dispatch — `grain(T)(ref T val) if(is(T==enum))` casts to the base type and
grains that, a chain of nested `ref`-forwarding calls and a pointer
reinterpret) all *passed* under `Interpreter`, isolating the gap: a direct
field or scalar `==` already agreed, but comparing the *whole struct* via
`==` did not, even for a minimal `struct Holder { Enum e; }` with no cast,
pointer, or decode machinery at all (`Holder.init == Holder(Enum.Foo)`).

Root: dmd lowers a POD struct's `==` (no user `opEquals`) into an `is`
expression rather than an `EqualExp` — confirmed with a throwaway trace of
`assert_.e1.op` inside the `AssertExp` branch (impl.d), reverted before
commit — so `Walker.runIdentityExpression` (impl.d) ran the comparison, not
`runEqualExpression`/`equalValues`. `runIdentityExpression` used a raw
`left == right` (`Value`'s own `opEquals`, a strict `SumType` compare) with
no per-field recursion or numeric-scalar coercion. Separately, `Value.
enumValue` (the `EnumValue` `SumType` member, tagged with the member's
display name) is only constructed by `runExpression` for an `IntegerExp`
whose `.type.ty == Tenum` — i.e. a literal enum-member reference — every
other origin (default-init via `defaultValue`, whose `Type.toBasetype`
dispatch resolves an enum to its underlying scalar `TY`, or any computed/
decoded value) keeps a plain scalar `Value`. Both tag kinds carry the
identical numeric value and a *scalar* `==`/`equalValues` already treats
them as equal (`isNumericScalar` accepts `EnumValue`, compared via
`.asReal`), but the raw `SumType` compare `runIdentityExpression` used
requires identical tags, so a `EnumValue`-tagged field never equalled a
same-valued plain-scalar field in a whole-struct comparison even though
real D's memberwise struct equality does.

Fix: `equalValues` (impl.d) gains a `Struct`-vs-`Struct` branch,
`equalStructValues`, recursing field-by-field through `equalValues` itself
(mirroring the existing `Array`-vs-`Array` branch, `equalArrayValues`), so
each field gets the same numeric-scalar coercion a top-level `==` already
applies. `runIdentityExpression` routes its struct-vs-struct case through
this same `equalValues` instead of the raw compare; every other `is`
comparison (pointers, class references, floats) keeps its existing
raw-value identity semantics.

Exposing fixture `struct.equalityComparesEnumFieldByValueAcrossOrigin`
(`tests/ut/backends/runner/lang/structs.d`): `enum Enum { Foo, Bar, Baz }`,
`struct Holder { Enum e; }`, comparing a default-initialised `Holder` to a
literal-constructed one holding the same member, asserting they're equal.
Confirmed red on `Interpreter` (`Holder(0) != Holder(Enum.Foo)`, the same
bare-number display bug seen in cerealed) before this fix, green on `Ctfe`,
`Bytecode`, `SystemLinker`, and `LLVMJit` throughout — full matrix, nothing
omitted.

cerealed impact: `bin/bench.sh -b interpreter -b system-linker --dub
cerealed` re-measured before/after. Before: 13 mismatches, including both
`structs.d(146)` (`EnumStruct`) and `structs.d(298)` (`MqttFixedHeader`).
After: both are gone; cerealed drops to 11 mismatches with no
newly-unmasked classes. Remaining 11: `decode.d(262)` (`Expected struct.`,
untriaged), `encode_decode.d(75)`/`(80)` and `reset.d(9)` (ScopeBuffer
native-memory aliasing, representation-ceiling per §8, deferred to
value.md), `pointers.d(20)` (truncated `Value:` message, untriaged),
`pointers.d(62)` (`address of dotVariable`, untriaged),
`pointers.d(82)` (`shouldThrow!RangeError` miss, untriaged),
`property.d(12)` ×2 (fuzz-seeded float property test, representation-
ceiling per §8's double/float-reinterpret exclusion), `static_array.d(7)`
(`Expected array.`, untriaged), and `structs.d(22)` (`DummyStruct`, a
`double`/AA field showing reinterpret-cast garbage — representation-
ceiling — plus an unrelated `string`-vs-array-of-int display detail on the
same test, not separable from the ceiling class without its own fixture).

**2026-07-14 (address-of-struct-field root, closed).** Triaged the 11
remaining cerealed mismatches (`bin/bench.sh -b interpreter -b
system-linker --dub cerealed`, HEAD `89863f28`, with a throwaway
`failure.location`-and-full-`message` probe in `testResultsMismatches`,
reverted before commit). `pointers.d(62)` (cerealed's
`struct.with.class.reference` test) is language-surface, not
representation-ceiling: `Walker.addressOfExpression`'s `DotVarExp` branch
(impl.d) only handled a struct's **static-array** field (`&field` /
`field.ptr`, routed through `arrayPointer`); any other field type fell
through to the generic `Unsupported eval expression: address of
dotVariable` throw. cerealed's test takes `&decOuter.inner` and
`&outer.inner`, the address of a class-reference-typed struct field, to
assert the decoded object is distinct from the original
(`shouldNotEqual(&decOuter.inner, &outer.inner)`).

Fix: the `DotVarExp` branch gains an else case producing a fresh,
uniquely-identified single-value pointer — `Value.arrayPointerValue(
[runExpression(dot)], ++allocationCount, 0)` — mirroring the existing
`runNewScalarPointerExpression`'s `new int` pattern (impl.d) rather than
inventing a new representation. The fresh `allocationCount` id guarantees
`&a.field !is &b.field` for distinct receivers; it is read-only (a value
snapshot of the field at the time the address was taken, not aliased to
the field storage), so identity is stable only while the field's value
stays unchanged — `p is &s.x` goes false again once `s.x` is written, a
known representation-ceiling limitation deferred to value.md. This is
sufficient here since neither this fixture nor cerealed's test writes
through the pointer — write-through support for an arbitrary field
address is a separate, deeper gap, not attempted.

Exposing fixture
`pointer.addressOfStructFieldIsDistinctAcrossInstances`
(`tests/ut/backends/runner/lang/expressions.d`): a `Holder { int value; }`,
two separately-constructed locals with equal field values, asserting
`&a.value !is &b.value` and both dereference to the seeded value.
Confirmed red on `Interpreter` (`Unsupported eval expression: address of
dotVariable`) before this fix, green on `SystemLinker`/`LLVMJit`
throughout. `Ctfe` omitted: DMD CTFE genuinely refuses this construct at
compile time (`cannot cast '&Holder(7).value' to 'ulong' at compile
time`), a real CTFE restriction, not a gap to close. `Bytecode` omitted:
`AddrExp` of a `DotVarExp` is not implemented there yet (still under
active development).

cerealed impact: `bin/bench.sh -b interpreter -b system-linker --dub
cerealed` re-measured before/after. Before: 11 mismatches, including
`pointers.d(62)`. After: gone, no newly-unmasked classes; cerealed drops
to 10 mismatches: `decode.d(262)`, `encode_decode.d(75)`/`(80)`,
`pointers.d(20)`, `pointers.d(82)`, `property.d(12)` ×2, `reset.d(9)`,
`static_array.d(7)`, `structs.d(22)` — unchanged from the list above
except `pointers.d(62)`'s removal. Of these, `encode_decode.d(75)`/`(80)`,
`property.d(12)` ×2, `reset.d(9)`, and `structs.d(22)` stay
representation-ceiling (deferred to value.md per §8); `decode.d(262)`,
`pointers.d(20)`, `pointers.d(82)`, and `static_array.d(7)` remain
untriaged.

**2026-07-14 (unconditional `ref`-argument write-back re-evaluation,
`pointers.d(82)` closed).** Triaged the 4 untriaged cerealed classes
(`bin/bench.sh -b interpreter -b system-linker --dub cerealed`, HEAD
`466d5396`). `decode.d(262)` (`@disable this()` decode) and
`static_array.d(7)` stayed untriaged (deferred, see below);
`pointers.d(20)` is a `Value`-identity/content gap, unrelated to this
entry. `pointers.d(82)` (`pointer.to.int`:
`shouldEqual(*dec.value!(int*), *i)`) turned out **not** to be a
representation gap in the decode chain itself: a standalone hand-rolled
reproduction of cerealed's exact `grain`/`grainReinterpret`/nested
`auto ref` forwarding (`int*` → reinterpret-cast `uint*` → byte-at-a-time
`ubyte` reads), using plain `assert`, passed on `Interpreter` first try.
Bisected by re-running cerealed's real `tests/pointers.d` file verbatim
as a standalone (non-dub) fixture with `--import-path` pointed at the
vendored `cerealed`/`concepts` sources: the identity-comparison test
(`pointers.d(20)`) reproduced immediately, but `pointer.to.int` only
failed inside the full 32-module `--dub cerealed` run, never in
isolation with plain `assert` in place of unit-threaded's `shouldEqual`.
Swapping the assert-based reproduction for a real `shouldEqual(*dec.
value!(int*), *i)` call (unit-threaded's `shouldEqual(V, E)(auto ref V
value, auto ref E expected, ...)`) reproduced it standalone too,
isolating the differentiator to the `auto ref` call, not dub-mode or
module ordering.

Root: `*dec.value!(int*)` is a `PtrExp`, always an lvalue in D, so `auto
ref` genuinely binds `value` by `ref` here — real D agrees the parameter
is `ref`. `Walker.writeBackRefArguments` (impl.d) wrote back through
*every* `ref` parameter unconditionally after the call returned,
regardless of whether the callee's body ever assigned to it (`shouldEqual`
only reads `value`/`expected` to compare them). For a `ref` argument
spelled as a `PtrExp`, the write-back path (`writeLocation`'s `*ptr = ...`
branch) re-evaluates `ptr.e1` to relocate the write destination — here,
`ptr.e1` is `dec.value!(int*)` itself, a decoding call with a side effect
(consuming bytes from `_bytes`). Re-running it a second time hit
`_bytes[0]` on an already-fully-consumed decerealiser and threw a bogus
`RangeError` (`index [0] is out of bounds for array of length 0`) instead
of the intended comparison — compiled D never re-evaluates a `ref`
argument's lvalue after the call (the address is bound once), so this was
a pure interpreter artifact of the call-by-value-plus-write-back
simulation, not a missing feature.

Fix: `writeBackRefArguments` now receives the call's original argument
`Value`s (already computed by every caller for `bindFunctionParameters`)
alongside the post-call `child.locals` snapshot, and skips the whole
write-back — including the location expression's re-evaluation — when
the parameter's final value equals what it was seeded with. This is a
general `ref`-argument correctness fix, not specific to `PtrExp`: it also
prevents the same double-execution for a `ref` argument spelled as a
ref-returning call (`writeLocation`'s `CallExp` branch actually re-runs
the callee), which was an unnoticed sibling of the same defect. Every
call site of `writeBackFunctionState`/`writeBackMemberFunctionState`
already had the argument `Value[]` in scope and now forwards it.

Exposing fixture
`refArgument.sideEffectingPointerDerefNotReEvaluatedWhenUnwritten`
(`tests/ut/backends/runner/lang/structs.d`): a `Decoder` struct whose
`decodeNext()` pops one `int` off a slice and returns a freshly-allocated
pointer to it (mirroring cerealed's decode-then-return-pointer shape,
without cerealed), passed dereferenced as a `ref` argument to a `compare`
function that never assigns to its parameters. Confirmed red on
`Interpreter` (`index [0] is out of bounds for array of length 0`, the
same message cerealed produced) before this fix; green on `Ctfe`,
`Bytecode`, `SystemLinker`, and `LLVMJit` throughout — full matrix,
nothing omitted.

cerealed impact: `bin/bench.sh -b interpreter -b system-linker --dub
cerealed` re-measured before/after. Before: 10 mismatches. After:
`pointers.d(82)` gone, no newly-unmasked classes; cerealed drops to 9
mismatches: `decode.d(262)`, `encode_decode.d(75)`/`(80)`,
`pointers.d(20)`, `property.d(12)` ×2, `reset.d(9)`, `static_array.d(7)`,
`structs.d(22)`. Of these, `encode_decode.d(75)`/`(80)`, `property.d(12)`
×2, `reset.d(9)`, and `structs.d(22)` stay representation-ceiling
(deferred to value.md per §8); `decode.d(262)`, `pointers.d(20)`, and
`static_array.d(7)` remain untriaged (checked this session:
`decode.d(262)`'s `@disable this()` struct hits `Expected struct.` via
the `T val = void;` property-getter overload, a language-surface gap in
aggregate default-construction, not attempted this rung;
`static_array.d(7)`'s `Expected array.` and `pointers.d(20)`'s `Value`
content-vs-identity mismatch are each their own untriaged root).

**2026-07-14 (struct-pointer identity root, `pointers.d(20)` closed).**
Triaged the 9 remaining cerealed mismatches (`bin/bench.sh -b interpreter
-b system-linker --dub cerealed`, HEAD `df1b5b4a`, full-message throwaway
probe in `testResultsMismatches`, reverted before commit — confirmed clean
via `git diff --stat`/`git status`). `pointers.d(20)`
(`struct.with.pointer.to.struct`) is the suggested `Value`-identity gap,
language-surface not representation-ceiling: `runNewStructPointerExpression`
(impl.d) returned `Value.pointerValue(structVal)` for every `new
StructType(...)`/`new StructType` with no user constructor — the
member-ctor branch, the aggregate-initialiser branch, and the no-args
default-init branch all funnel through this one `return`. `pointerValue`'s
`Pointer([target])` ctor never sets `allocation`/`offset`, so *every*
struct-pointer `new` this way carries the same all-zero identity, and
`equalValues`'s fallback (`left == right`, `Value.opEquals` → `data ==
other.data` → the SumType's field-wise `Pointer` compare) considers two
such pointers equal whenever their pointed-to contents match — a pure
content compare masquerading as identity. cerealed's test allocates
`outer.inner` via `new InnerStruct(7, 2)` and cerealed's own decode path
(vendored `cereal.d:235`, `val = new ValueType;`) allocates
`decOuter.inner` the same way; both land on allocation id 0, so
`decOuter.inner.shouldNotEqual(outer.inner)` (unit-threaded, real D,
lowering to `!=`) fails on `Interpreter` even though the two are genuinely
distinct heap objects on `SystemLinker`.

Fix: that one `return` now assigns a fresh id —
`Value.arrayPointerValue([structVal], ++allocationCount, 0)` — mirroring
`runNewScalarPointerExpression`'s existing `new int`-style pattern and the
§9.7 address-of-struct-field fix's fresh-`allocationCount` idiom. Scope:
only this call site changed; the sibling body-less-native-constructor path
(`runNewStructNativeConstructor`, its own `return
Value.pointerValue(constructed)`) is a different `NewExp` branch not
exercised by this fixture or by cerealed's disagreement, so it is left
untouched — a candidate for the same fix if a future gap implicates it.

Exposing fixture `pointer.newStructPointersWithEqualContentAreDistinct`
(`tests/ut/backends/runner/lang/expressions.d`): a runtime-seeded `Inner`
struct `new`-allocated twice with equal field contents, asserting `a !is
b` and `*a == *b`. Confirmed red on `Interpreter` before the fix
(`const(Pointer)([Inner(7)], 0, 0) is const(Pointer)([Inner(7)], 0, 0)`,
the identical all-zero-identity shape cerealed hit); green throughout on
`Ctfe`, `SystemLinker`, `LLVMJit`. `Bytecode` omitted: dereferencing a
struct pointer (`*a`) is not implemented there yet (still under active
development).

cerealed impact: `bin/bench.sh -b interpreter -b system-linker --dub
cerealed` re-measured before/after. Before: 9 mismatches. After:
`pointers.d(20)` gone, no newly-unmasked classes; cerealed drops to 8
mismatches: `decode.d(262)`, `encode_decode.d(75)`/`(80)`, `property.d(12)`
×2, `reset.d(9)`, `static_array.d(7)`, `structs.d(22)`. Of these,
`encode_decode.d(75)`/`(80)`, `property.d(12)` ×2, `reset.d(9)`, and
`structs.d(22)` stay representation-ceiling (deferred to value.md per
§8); `decode.d(262)` (`@disable this()` / `T val = void;` decode,
`Expected struct.`) and `static_array.d(7)` (`Expected array.`) remain
untriaged, each its own root.

**2026-07-14 (void-init struct/aggregate `ref`-parameter root,
`decode.d(262)` closed).** Triaged the 2 remaining tractable classes
(`bin/bench.sh -b interpreter -b system-linker --dub cerealed`, HEAD
`86ad4fb4`). `decode.d(262)` (cerealed's "Types with @disable this can
be encoded/decoded" test) is language-surface: `Decerealiser.value`'s
`T val = void;` property-getter overload (used because `T()` does not
compile for a `@disable this()` struct) then calls `grain(this, val)`,
which reaches the struct's field only through a chain of nested `ref`-
forwarding calls (`grainAllMembersImpl` -> `grainAggregateMember` ->
`grain(__traits(getMember, val, member))`) — the same shape as the
already-closed scalar `.grain.b` void-init-`ref` gap above, but one
level deeper: the forwarded expression is a struct **field**
(`DotVarExp`), not a bare local.

Root: `Walker.runRefArgumentExpression`'s existing deferred-read
special case (impl.d, the earlier `.grain.b` fix) only marks the
*caller's* argument as unread; it does nothing for the *callee's own*
parameter binding. `Walker.bindFunctionParameters` stored the deferred
`Value.void_` placeholder straight into the callee's `locals` without
recording it in the callee's own `uninitializedLocals`. `runExpression`'s
`VarExp` branch already special-cases a variable found in
`uninitializedLocals`, materialising a default struct/array value so
field access keeps working (mirroring dmd's own field-granular void
diagnostic) — but that branch never ran for the callee's parameter,
since it wasn't marked uninitialized there. So a nested `DotVarExp`
field read on the still-void parameter (`runDotVarExpression`'s
`runExpression(dot.e1)`) fell through to a plain `locals` lookup,
returning the bare `Value.void_` placeholder, and field extraction on a
non-`Struct` value threw `Value.structFieldAt`'s generic diagnostic,
"Expected struct."

Fix: `bindFunctionParameters` now also marks a `ref` parameter in the
callee's own `uninitializedLocals` whenever its bound argument value is
`Value.void_`, mirroring the caller-side deferred-read seed. This is a
general fix, not struct-specific: it makes a nested ref-forwarding
chain of any depth (scalar or aggregate) consistently defer through the
same "still uninitialized" handling at every frame, instead of only the
outermost one.

Exposing fixture
`refArgument.voidStructLocalFieldWritableThroughNestedRefWrite`
(`tests/ut/backends/runner/lang/structs.d`): a `Holder { ubyte i; }`,
`writeByte(ref ubyte)` forwarded through `grainField(ref Holder val) {
writeByte(val.i); }`, called from a `Holder val = void;` local,
asserting the field is readable as 42 after the call. Confirmed red on
`Interpreter` (`Expected struct.`, the identical cerealed message)
before this fix, green on `Ctfe`, `Bytecode`, `SystemLinker`, and
`LLVMJit` throughout — full matrix, nothing omitted.

cerealed impact: `bin/bench.sh -b interpreter -b system-linker --dub
cerealed` re-measured before/after. Before: 8 mismatches. After:
`decode.d(262)` gone, no newly-unmasked classes; cerealed drops to 7
mismatches: `encode_decode.d(75)`/`(80)`, `property.d(12)` ×2,
`reset.d(9)`, `static_array.d(7)`, `structs.d(22)`. Of these,
`encode_decode.d(75)`/`(80)`, `property.d(12)` ×2, `reset.d(9)`, and
`structs.d(22)` stay representation-ceiling (deferred to value.md per
§8); `static_array.d(7)` (`Expected array.`) remains untriaged — the
sole remaining candidate this session left unattempted, per the
"one clean root" guidance.

**2026-07-14 (void-init static-array slice-alias write-back root,
`static_array.d(7)` closed).** Triaged the last untriaged cerealed class
(`bin/bench.sh -b interpreter -b system-linker --dub cerealed`, HEAD
`ac73fbdf`). cerealed's `static.array` test (`static_array.d(7)`) calls
`Decerealiser.value!(int[2])`, whose `T val = void;` overload (taken
because `int[2]()` does not compile) then runs cereal.d's static-array
`grain`: `foreach (ref e; val) cereal.grain(e);`. Bisected with a chain of
standalone probes (a hand-rolled reinterpret-cast `grain`/`ungrain` pair
matching cereal.d's shape, then a plain direct-write reproduction with no
reinterpret cast at all) down to a two-line root: `void fillPair(ref
int[2] val) { foreach (ref e; val) e = ...; }` called with a void-init
caller local reproduces standalone; the same call with a *default*-init
local (no `= void`) passes today — isolating the differentiator to
void-init, not the reinterpret cast, the templated `value!T` dispatch, or
`~=`'s operator overload.

Root: dmd's foreach-to-for lowering slices *every* static array, even a
plain local/parameter (`T[] __r = val[];`), not only aggregate-field
cases (§9.7's earlier foreach-ref-over-struct-field-array entry above).
`Walker.recordSliceAlias` (impl.d) records this correctly (`__r`'s
`SliceAlias.source` is `val`), and the per-element write inside the loop
correctly routes through `writeThroughSliceAlias`. But
`writeThroughSliceAlias` read the alias source's `locals` entry as-is:
`bindFunctionParameters` binds a `ref` parameter to the caller's deferred
`Value.void_` placeholder (§9.7's void-init-ref-parameter seeding), so
`val`'s `locals` entry is the bare placeholder, not a real `Array`.
Rebuilding it via `Value.withArrayElement` then threw "Expected array."
instead of writing the element — the identical cerealed message, located
via a throwaway `stderr.writefln` trace at the top of
`writeThroughSliceAlias` and its sibling `writeThroughArrayElementAlias`
(both reverted before commit), which showed the alias chain
`e -> __r -> val` and `val`'s still-void `locals` entry precisely at the
write.

Fix: `writeThroughSliceAlias` now materialises the alias source's default
value first (`locals[alias_.source] = defaultValue(alias_.source)`)
whenever that source is still in `uninitializedLocals`, mirroring the
read-path materialisation `runExpression`'s `VarExp` branch already
applies to a directly uninitialized local. This covers both of the
function's branches (the plain-array case exercised here and the
existing struct-field-array case) since `defaultValue` already dispatches
on the variable's declared type. `writeThroughArrayElementAlias` (the
sibling alias kind for a `ref` bound directly to an indexed source with
no intervening slice) needs no change: tracing confirmed dmd's lowering
always introduces the slice temporary for a static array, so that path
is not exercised by this class; it is left as its pre-existing
"Unsupported interpreter array element alias target." refusal if a future
construct ever reaches it uninitialized.

Exposing fixture `staticArray.foreachRefWritesVoidInitialisedElements`
(`tests/ut/backends/runner/lang/arrays.d`): a `void fillPair(ref int[2]
val, int first)` writing both elements via `foreach (ref e; val)`, called
from `int[2] result = void;`, asserting the caller's array holds both
written values afterward. Confirmed red on `Interpreter` ("Expected
array.", the identical cerealed message) before this fix, green on
`Ctfe`, `SystemLinker`, and `LLVMJit` throughout. `Bytecode` omitted:
still under active development, does not yet write through this `ref`
foreach loop variable (every element reads back as `0`) regardless of
void-init status.

The native-layout work validated this rung's durable diagnosis: the remaining
classes at this frontier were representation-ceiling cases (ScopeBuffer
native-memory aliasing, fuzz-seeded double/float reinterpret, and a
`double`/AA field reinterpret-cast), not missing language-surface behavior.
Those classes are closed and the Cerealed acceptance command is green.

**2026-07-14 (Fable review: field-address identity, float writeback
compare, snapshot write refusal).** A code review of the `&s.field`
address-of rung (this section's 2026-07-14 "address-of-struct-field
root" entry) and the ref-argument write-back skip (this section's
2026-07-14 "unconditional `ref`-argument write-back re-evaluation"
entry) found three defects, fixed together:

1. `addressOfExpression`'s `AddrExp(DotVarExp)` non-static-array branch
   minted a fresh `++allocationCount` identity on *every* evaluation of
   `&s.field`, so re-taking the same field's address gave a different
   identity each time (`&a.value !is &a.value`), unlike real D. Fixed by
   memoizing the allocation id per (receiver `VarDeclaration`, field
   index) in a new `size_t[size_t][VarDeclaration]
   fieldAddressAllocations` map, propagated across child `Walker` frames
   the same way `arrayAllocations` already is. A receiver that cannot be
   resolved to a variable (e.g. `&call().field`) still gets a fresh id
   every time. Exposing fixture
   `pointer.addressOfStructFieldIsStableAcrossReEvaluation`
   (`tests/ut/backends/runner/lang/expressions.d`).

2. Sibling defect: writing through a `&s.field` pointer silently wrote
   into the pointer's own throwaway value snapshot instead of `s`'s
   storage, losing the write with no diagnostic (previously this
   refused loudly; the address-of-struct-field rung's fresh-identity
   fix made it fall through to a silent write instead). Every id minted
   by the `&s.field` path (memoized or fresh) is now also recorded in a
   `bool[size_t] fieldSnapshotAllocationIds` set; `writeLocation`'s
   `PtrExp` branch throws `Unsupported interpreter assignment target.`
   when the target pointer's allocation id is a known field snapshot,
   instead of silently rewriting it. `new Struct(...)`/`new Class(...)`
   pointer writes are unaffected only once the `new`-with-user-ctor
   child `Walker` correctly seeds and merges back `allocationCount`
   (and `fieldAddressAllocations`/`fieldSnapshotAllocationIds`) the same
   way every other child frame does; without that, ids minted inside
   such a ctor can numerically collide with a live parent field-
   snapshot id and get wrongly refused (fixed 2026-07-14, see the
   `pointer.newCtorPointerWriteNotRefusedAfterFieldAddress` entry
   below). There is no separate id namespace — `allocationCount` is one
   shared counter — so collisions are avoided by propagation, not by
   construction.
   Fixtures: `pointer.addressOfStructFieldWriteThroughUpdatesField`,
   split by backend — `SystemLinker` pins the real aliasing
   write-through, a separate `Interpreter`-only block asserts the loud
   refusal via `shouldThrowWithMessage` (both in
   `tests/ut/backends/runner/lang/expressions.d`).

3. Unrelated defect in the same review, in `writeBackRefArguments`'s
   unchanged-parameter skip check (this section's 2026-07-14
   "unconditional `ref`-argument write-back re-evaluation" entry): it
   compared `Value`s with plain `==`, wrong for floating scalars two
   ways — `-0.0 == 0.0` is `true`, so a callee that genuinely rewrites a
   negative zero to a positive zero got that write silently dropped (a
   real regression risk, not just a missed optimisation), and `NaN ==
   NaN` is `false`, so an unchanged `NaN` ref argument would not be
   skipped, re-executing a side-effecting location expression exactly
   like the original `pointers.d(82)` bug (for the `NaN` case only).
   Fixed with a new interpreter-local `identicalValues(a, b)`, used only
   for this skip decision: floating scalars (`float`/`double`/`real`)
   compare by bit pattern (`asReal is asReal`, matching D's `is`
   semantics for floats), everything else defers to plain `==`.
   Exposing fixture
   `refArgument.floatWriteBackSkipComparesBitPatternNotEquality`
   (`tests/ut/backends/runner/lang/structs.d`); `Bytecode` omitted
   (floating-point division not implemented there yet, unrelated to
   this fix).

All three fixtures confirmed red on `Interpreter`/green on
`SystemLinker` before the fix (reconstructed on the pre-fix parent per
this section's 2026-07-09 handoff protocol). The durable regression fixture is
`refArgument.sideEffectingPointerDerefNotReEvaluatedWhenUnwritten`; it keeps
the closed `pointers.d(82)` `ref`-argument rung closed.

**Sibling gap, not fixed here (Finding 4, plan note only).** The rung-6
`recordSliceAlias` `DotVarExp` branch (this section's
foreach-ref-over-struct-field-array entry) resolves the field's owner
only when the sliced aggregate's receiver (`slice.e1.isDotVarExp.e1`)
is itself a plain `VarExp`. Two related shapes still fall through to
`sliceAliases.remove(variable)`, silently losing element writes, same
as the base (pre-rung) behaviour: a member function's `foreach (ref e;
this.field)` (the receiver is a `ThisExp`, not a `VarExp`), and a
nested-field foreach-ref such as `foreach (ref e; outer.inner.items)`
(the receiver is itself a `DotVarExp`, not a `VarExp`). Both are
untested and unfixed; a future rung should extend
`recordStructFieldAlias`/`recordSliceAlias`'s owner resolution to walk
an arbitrary `DotVarExp`/`ThisExp` chain instead of requiring a single
`VarExp` hop.

**2026-07-14 (regression fix: `new`-ctor allocation-id collision with a
field snapshot).** A code review found that the previous entry's two
new `Walker` maps (`fieldAddressAllocations`/`fieldSnapshotAllocationIds`)
exposed a pre-existing gap in the `new T(...)`-with-user-constructor
child `Walker` sites (`runNewStructPointerExpression`,
`runNewClassExpression`, impl.d): both restarted `allocationCount` at 0
for the child instead of seeding it from the parent, and never merged it
(or the two maps) back — unlike every other child-frame site
(`runFunction`, `runMemberFunction`, `refReturningCallAddress`, and the
other existing child sites), which all seed and merge `allocationCount`
plus these maps. A pointer minted inside such a ctor (`q = new int;`)
could therefore land on the same small id as an already-live parent
field-snapshot id, so a later legitimate write through it was wrongly
refused by `writeLocation`'s `PtrExp` branch. Fixed by seeding and
merging `allocationCount`/`fieldAddressAllocations`/
`fieldSnapshotAllocationIds` at both sites, matching the established
six-site pattern exactly. Exposing fixture
`pointer.newCtorPointerWriteNotRefusedAfterFieldAddress`
(`tests/ut/backends/runner/lang/expressions.d`): confirmed red on
`Interpreter` (`Unsupported interpreter assignment target.`), green on
`SystemLinker`, before this fix.

### 9.8 Rung 8 — real file IO (`std.stdio.File` create/write/read)

**Contract.** `File(path, "w")`, `f.write(...)`, scope-exit close via the
refcounted Impl, and `std.file.readText` agree with `SystemLinker`. Driven by
the user-visible fixture `sys/file.d` (`file.createWriteRead`), with the
per-root standalone fixtures `struct.voidInitialisedFieldSliceAssignment`
(lang/) and `strlen.localBuffer` (sys/cstdlib.d).

**Landed 2026-07-06.** The chain of roots this exposed, each fixed at its
seam:

```text
- slice assignment through a struct-field base (`s.buf[i .. j] = src[]`),
  the real error behind the §5-masked tempCString failure;
- pointer-typed integer constants (TempCStringBuffer.useStack's
  `cast(T*) size_t.max`) as native pointer values;
- `&field` of a static-array struct member as an array pointer;
- C strings backed by retained native character storage (fopen's path);
- delegating struct constructors (`this(...)` forwarding, File's ctor);
- native-memory struct loads/stores through typed places
  (malloc'd Impl reads/writes; `Tsarray` fields for `stat_t`);
- struct out-parameters at flagged `&local` call sites (fstat);
- core.internal.atomic hooks (asm bodies interpreted as plain load/store/
  rmw; alignment asserts short-circuited) — File's refcount;
- `ref` writeback through `*pointer` arguments (core.atomic's shared
  overloads forward `*cast(T*)&val`) — the lost refcount store;
- postblit-call declaration initializers (`(copy = orig).__postblit()`)
  keeping the blitted variable, not the call's incidental result;
- native calls writing directly through pointer-into-array addresses
  (POSIX `read` buffers);
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
`tests/ut/backends/runner/lang/imports.d` for imported *function bodies*.

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
sys/random.d — sys/ because the green path reads the platform entropy
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
path; if a deeper marshalling gap surfaces once the initializer resolves, it
belongs to the legacy bridge until the Interpreter address migration.

**Done (2026-07-08) — fix landed; Interpreter fixture blocked
downstream by a legacy-FFI gap.** `resolveNonRootInitializer` (impl.d, near
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
`getrandom` syscall. That is a native-boundary feature (scalar-local byte view
+ `getrandom` fill + byte writeback), not a source-language workaround.

The exposing fixture landed as `sys/random.d`
`random.unpredictableSeedReadsNonRootInitializer` on the widest **green**
matrix — `SystemLinker` + `LLVMJit` — with `Interpreter` **omitted** per
§8 (the omission is the documentation; no pinned refusal), pending the
Interpreter native-boundary fix. `Ctfe` (no getrandom source) and Bytecode are
likewise omitted. The Rung 9 fix's own evidence is the standalone-repro
progression (`identifier` → `Expected pointer` at the identical entropy
site); the cerealed 21× `identifier` class converts to the same
getrandom FFI class rather than disappearing, so the native-boundary fix
finally clears it from the §7 inventory.

### 9.10 Known `signbit` interception defect

`tryInterpreterBuiltin`'s bare-identifier `signbit` fallback
(`interception_guard.d:199-206`) matches on the identifier `signbit` alone,
with no module check, so a user or library function literally named
`signbit` would be silently intercepted and given
`std.math.traits.signbit`'s behaviour instead of its own. This is a
language-surface bug per §8's triage rule — fixable at the root by adding a
module check, not representation debt deferred to `value.md` — surfaced and
documented by the guard's own commit but deliberately not fixed there (that
commit's remit was enforcement, not behaviour change).

**Resolved (2026-07-09, follow-up session).** The `nativeExceptionRoot` defect
noted here (classifying `Error` vs `Exception` by name prefix
(`core.exception.*`/`object.*` + `Error` suffix), and fabricating a type-name
list that jumps straight from the thrown class to its root, omitting
intermediate bases) was fixed at the root.

`errorIsNotCaughtByExceptionHandler` (`lang/exceptions.d`) does **not** cover
this: it does `throw new Error("fatal")` from interpreted code, which goes
through `runNewClassExpression`/`classDefaultValue` using the real
`ClassDeclaration` dmd already resolved for the `new` expression — it never
calls `nativeExceptionBaseObject`/`nativeExceptionRoot` at all. Only two call
sites reach that heuristic: `throwRangeError` (a hardcoded
`"core.exception.RangeError"` literal, always correctly classified by the
prefix pattern) and `nativeExceptionObject` (FFI-caught native throwables,
`className` from the real `throwable.classinfo.name`).

Reproducing defect 1 (Error misclassification) needed care: `ffi/oldffi.d`'s
native call site only ever `catch (Exception exception)`s ("Error stays
fatal" per its own comment), so a natively-thrown `Error` subclass can *not*
reach `nativeExceptionRoot` as the directly-thrown object — it propagates as
a raw, uncaught native `Throwable` straight through the whole interpreter
call stack (confirmed: a first fixture that threw a dependency-image `Error`
subclass directly crashed the whole `bin/ut` process with a native
backtrace, not a graceful `TestResult` failure — a real but separate,
out-of-scope bug). The reachable route is `nativeCallExceptionFrom`'s
`.next`-chain recursion in the legacy bridge, which follows `.next` regardless
of its dynamic type: a native `Exception` (caught normally) chained to an
`Error` via `.next` carries that `Error`'s `classinfo.name` into
`nativeExceptionBaseObject` when the interpreted code reads and rethrows
`caught.next`.

Red-first evidence (both added to `tests/ut/backends/runner/sys/
dependency_image.d`, `SystemLinker` oracle vs `Interpreter`, pre-fix):

- `dependencyImage.nativeChainedErrorSubclass.Interpreter` (defect 1): a
  dependency image throws `Exception("outer failure")` chained
  (`.next`) to `DependencyError : Error` ("root cause"). Interpreted code
  catches the outer `Exception`, then rethrows `caught.next` and expects
  `catch (Error)` to match. Oracle: passed. Interpreter (pre-fix): failed —
  `Expected: true / Got: false` on `interpreted[0].passed`, because
  `nativeExceptionRoot("dep_image_chained_error_fixture.DependencyError")`
  doesn't match `"core.exception."`/`"object."` prefix, so root is wrongly
  `"Exception"` and the rethrown value's fabricated type names omit
  `"Error"`.
- `dependencyImage.nativeIntermediateBaseException.Interpreter` (defect 2):
  a dependency image throws `DependencyException : DependencyBaseException :
  Exception`; interpreted code catches `DependencyBaseException`. Oracle:
  passed. Interpreter (pre-fix): failed — `interpreted[0].message` was
  `"dependency failed"` (the uncaught exception's own message), because the
  fabricated type-name list jumps straight from `DependencyException` to
  `"Exception"`, omitting the intermediate `DependencyBaseException`.

**The fix.** `nativeExceptionBaseObject` (`impl.d`) gained a second
resolution attempt between the existing lexical-scope search
(`dynamicClassDeclarationByName`) and the string-heuristic fallback: a new
free function `classDeclarationByQualifiedName` searches every module
`Module.amodules` the frontend has semantically analysed (druntime/Phobos
modules the source imports are analysed by dmd-as-a-library, so this reaches
classes outside the lexical scope chain) for an exact `classInfoName` match,
reusing the existing `classDeclarationByNameInScope` walk (its dual
`className`/`classInfoName` match cannot misfire here: a fully-qualified name
can never equal a bare identifier). When found, the real `ClassDeclaration`
feeds the already-correct `classDefaultValue`/`classTypeNames`/
`classHierarchy` path — the true base chain, including intermediate bases and
interfaces — instead of `nativeExceptionRoot`'s name-prefix guess. The string
heuristic remains only as the last-resort fallback for classes the frontend
genuinely does not know (e.g. one defined solely inside a loaded shared
library with no corresponding import in the interpreted source).

`throwRangeError` is not regressed:
`decodeLazyForwardedRangeErrorSeesReaderState` (`lang/cerealed.d`) explicitly
`import`s `core.exception : RangeError;` and `catch (RangeError)`s, so with
this fix `core.exception.RangeError` now resolves via the new
qualified-module search (previously it happened to be correctly classified
by the string heuristic instead); it stays green.

Matrix: `dependencyImage.nativeChainedErrorSubclass.Interpreter` and
`dependencyImage.nativeIntermediateBaseException.Interpreter` land
`Interpreter`-only (matching this file's existing dependency-image
convention of an inline `SystemLinker` oracle rather than a
`static foreach` backend matrix — other backends have no dlopen'd
dependency-image FFI machinery to exercise). Full regression sweep after the
fix: `lang/exceptions.d`, `lang/cerealed.d`, and
`backends/ffi/dependency_image.d` together — 314 tests, 0 failed, 1 expected
failure.

**Owed fixtures (work item, 2026-07-09).** #386 landed its fixes without the
§8 red-first fixtures; the drafts and reconstruction procedure are in the
2026-07-09 handoff above (§9.6/§9.7 ledger). Writing them is IN the plan, not
optional, and each lands under the §8 approval rule. Classification:

```text
ratchet fixtures (green today, pin oracle behaviour, protect the shim->real
migration — a fixture asserts behaviour, so it survives the shim's deletion):
(none outstanding)

gap fixtures (red on Interpreter, land with Interpreter OMITTED per §8 —
they document what the shims get wrong and what native layout must re-earn):
(none outstanding)
```

**Landed (2026-07-09).** `lazyForwardedAssertionThunkRunsExpression`
(lang/cerealed.d) reconstructed red-first per the procedure above: applied
alone on the parent of fix commit `7f09bd67` (parent `ee3594a9`, "interpreter:
handle GC array capacity hooks"), it fails on `Interpreter` with the exact
diagnostic `Unsupported eval call.` and passes on `SystemLinker`. Carried
forward onto this branch (after `7f09bd67`), it is green on
`Ctfe, Interpreter, SystemLinker, LLVMJit`. `BytecodeNewCore` is omitted:
lazy parameters are not yet implemented there (`Unsupported call in bytecode
core: expression()`).

**Resolved (2026-07-09, follow-up session).** The captured-locals snapshot
defect above was reproduced and fixed. Red-first evidence, reproved directly
on this branch: applying `decodeLazyForwardedRangeErrorSeesReaderState`
alone at this branch's pre-fix `aee073a5` (parent of the fix commit
`674e76a2` that actually makes it green here) fails on `Interpreter` with
`false != true` and passes on `SystemLinker`. This matches the `#386`-era
history recorded against `833c560c` (parent of fix commit `bf9d6836`), kept
here as context rather than as the proof, since that lineage predates this
branch. The minimal repro from the previous handoff was independently
re-run against `aee073a5` and fails exactly as described:

```d
void runIt(lazy ubyte expression) { expression; }

unittest {
    ubyte[] bytes = [1, 2, 3];
    runIt(bytes[1]);
}
// Interpreter: index [1] is out of bounds for array of length 0
// SystemLinker: passes
```

as does the struct-field-mutation companion repro:

```d
struct Counter { int value; }
void bump(lazy int expression) { expression; }

unittest {
    Counter counter;
    counter.value = 10;
    bump(counter.value = counter.value + 1);
    assert(counter.value == 11);
}
// Interpreter: 10 != 11
// SystemLinker: passes
```

**Root cause (corrected).** The previous handoff's hypothesis — that the
defect is a representation-ceiling gap because the snapshot doesn't carry
`arrayAllocations`/`arrayAllocationAliases` — does not hold up. A dynamic
array's backing storage lives inside `Value.Array` itself (`elements`,
`allocation`: real D slices), which already round-trips correctly through
an ordinary `Value[VarDeclaration]` dup; no parallel allocation-id map is
involved in a plain local read. The actual bug is simpler and is an
ordinary language-surface defect: `bindLazyFunctionParameter` runs as a
method of the **callee's** `Walker` (`child`, constructed in `runFunction`/
`runMemberFunction`/the ref-return call-location helpers), so its
`locals.dup` captured `child.locals` — for a non-nested plain call this is
just `datasegLocals` (globals only) — instead of the **caller's** real
frame, which is a different `Walker` instance entirely and was never
threaded through `bindFunctionParameters`. The caller's dynamic-array local
was therefore simply absent from the captured map, so reading it fell back
to a default (empty) array. This also explains the struct-mutation defect:
even had the snapshot been of the right frame, mutating a *dup* of it during
`runLazyArgument` never wrote anywhere the caller could see after the call
returned — the snapshot was disconnected in both directions.

**Triage classification: language-surface, not representation-ceiling.**
Per §8's triage rule, "lazy-parameter semantics" is explicitly called out
as language-surface (a missing/incorrect language behaviour any
representation needs), and that is what this is: a `lazy` parameter is a
delegate over the caller's live frame in real D, not a value snapshot taken
at an arbitrary (and here, wrong) point. The fix does not touch value
representation, boxing, or allocation identity at all — it corrects *which*
environment gets captured and how mutations flow back through it. Per §8,
this is fixed at the root with a red-first fixture, not shimmed or deferred
to `value.md`.

**The fix.** Two changes, both confined to the lazy-argument path:

1. `bindFunctionParameters` and `bindLazyFunctionParameter` gained an
   explicit `callerLocals` parameter, threaded from every call site that
   constructs a callee `Walker` and calls `child.bindFunctionParameters(...)`
   (`impl.d`, five sites — the two `new_.member` constructor-call sites are
   unchanged: a constructor with a `lazy` parameter already throws
   `Unsupported interpreter call arguments.` before reaching the capture
   line, since those two sites never build an `argumentExpressions` array).
   Each site passes its own `locals` (unqualified, i.e. `this.locals` — the
   real caller's frame) rather than leaving the callee to capture its own,
   nearly-empty one.
2. The capture, the same-parameter forward (`bindLazyFunctionParameter`'s
   already-lazy-argument branch), and the substitution in `runLazyArgument`
   all dropped their `.dup`. `Value[VarDeclaration]` is a D associative
   array — a reference to a heap hash table, not a value type — so storing
   `callerLocals` without duplicating it makes the captured environment
   literally the *same* table the caller's `locals` field still points at.
   Evaluating the thunk swaps `locals` to that table (no dup), so any
   mutation performed while evaluating it (e.g. a forwarded range's cursor
   advancing) mutates the caller's real frame directly and is visible the
   moment the call returns — matching a genuine closure with no separate
   write-back step, and correctly compounding across forwarding: each hop's
   `child.locals` for its own declared parameters stays independently
   `.dup`'d as before, only the lazy-capture table itself is shared.

This is the frame-reference fix, not a snapshot widened with more parallel
maps: no new tracking map was added, and `arrayAllocations` et al. were
never the problem.

**On the #386 drafts.** The unshipped `writeBackLazyArgumentSideEffects` in
the 2026-07-09 drafts (`386-drafts.patch`) was a snapshot-plus-explicit-
write-back scheme: dup the caller's locals at capture time, diff the
before/after snapshot inside `runLazyArgument`, fold changed keys into the
callee's own `locals`, then fold *that* into the true caller's `locals` on
function return via a new helper gated on "does this function have any
lazy parameter." Re-derivation for this fix confirms that design would
only propagate a mutation up exactly one call level per return, so a
value forwarded through two or more hops (as
`decodeLazyForwardedRangeErrorSeesReaderState` requires) would stall at
the first intermediate frame that doesn't already hold the mutated
variable as an existing key — it was never actually exercised end-to-end,
which is why the earlier "lazy-state wrong answer" note in this plan
overstated what `#386` had proven. It is superseded by the no-dup,
shared-table design above and was not landed in any form.

**Fixtures landed.**
- `decodeLazyForwardedRangeErrorSeesReaderState` (lang/cerealed.d): the owed
  fixture, unchanged from the draft body. Green on `Interpreter,
  SystemLinker` after the fix above.
- `lazyArgumentReadsCallerDynamicArray` (lang/cerealed.d): new, narrow
  standalone fixture for the dynamic-array-local read repro. Green on
  `Interpreter, SystemLinker`.

Both fixtures omit `BytecodeNewCore` (lazy parameters unsupported there —
consistent with `lazyForwardedAssertionThunkRunsExpression` above) and
`Ctfe`/`LLVMJit` (not exercised by this rung; the existing lazy fixture in
this file already covers those backends for the simpler thunk-invocation
case). Full `lang/` and `sys/` suites re-run clean after the change (2422
tests, 0 failed, 6 pre-existing expected failures).

**Landed (2026-07-09, owed-fixtures follow-up).** The char
integer-compatibility and float/double reinterpret-load fixtures owed
above were reconstructed red-first and landed in `lang/expressions.d`:
`pointer.dcharCompoundAssignThroughUintPointerIsIntegerCompatible`,
`pointer.floatBitsThroughUintPointerAreRawBits`, and
`pointer.doubleBitsThroughUlongPointerAreRawBits`.

Red-first evidence: applied alone at fix commit `82297fe9`'s parent
(`bf9d6836`, "interpreter: invoke lazy wrapper thunks"), `Interpreter`
fails all three, with `SystemLinker` green in every case (confirming a
genuine oracle-agreeing D construct, not UB):

- `dcharCompoundAssignThroughUintPointerIsIntegerCompatible`: refusal,
  `Expected integer-compatible scalar.`
- `floatBitsThroughUintPointerAreRawBits`: **wrong answer**, not a
  refusal — `1 != 1069547520` (`0x3FC00000`). The pre-fix path truncated
  `cast(uint)(1.5f)` to `1` via `Value.castTo!uint`'s numeric-conversion
  branch instead of reinterpreting the raw IEEE-754 bits.
- `doubleBitsThroughUlongPointerAreRawBits`: **wrong answer** —
  `1 != 4609434218613702656` (`0x3FF8000000000000`), same truncating-cast
  mechanism.

The two reinterpret fixtures being silent wrong answers rather than
diagnosed refusals makes them §7's most urgent class: an unguarded
representation gap that produces plausible-looking incorrect results
instead of failing loudly.

Backend matrix, verified green at this branch's HEAD:
- Fixture 1 (`dchar`): `Ctfe, Interpreter, SystemLinker, LLVMJit`.
  `Bytecode`/`BytecodeNewCore`/`IR` omitted (address-of-local and this
  compound-assignment shape are unimplemented gaps there, unrelated to
  this bug class).
- Fixtures 2a/2b (`float`/`double`): `Interpreter, BytecodeNewCore,
  SystemLinker, LLVMJit`. `Ctfe` omitted: real dmd CTFE has no
  byte-level memory model for floating-point locals and permanently
  refuses `cast(uint*)&floatLocal` (`cannot convert '&float' to 'uint*'
  at compile time`) — this is dmd's own restriction, not an
  in-development gap, but the fixtures merely omit it rather than pin
  the refusal. `Bytecode`/`IR` omitted (address-of-local unimplemented).

Bonus finding confirmed: `Ctfe` *does* support same-size integer-family
pointer reinterpretation (hence its presence in fixture 1's matrix, and
absence from 2a/2b — this is not an oversight, it is dmd CTFE's actual,
type-family-dependent behaviour).

Non-obvious construction finding, load-bearing for reproduction: a
`char`/`ubyte*` version of fixture 1 does **not** reproduce the bug —
DMD's frontend inserts an implicit promoting `CastExp` for sub-`int`-
sized operands in compound-assignment lowering, which re-masks the gap
before the interpreter's `asLong`/`castTo` ever runs. `dchar`/`uint*`
(4 bytes, already int-rank) is the necessary representative of the
char/wchar/dchar family — not an arbitrary substitution, since the
production fix treats all three identically via a single
`isSomeChar!T` branch. More generally, every "natural" D operator
context that reaches a scalar `Value` (shift, bitwise-assign, array
index, unary complement, case-range dispatch) already carries an
`int`/`ulong`-tagged `Value` by the time it matters, because DMD
inserts a promoting cast; the one place that does not is a pointer
dereference cast to a *different, same-size* type than the pointee's
declared type — the frontend's static type of `*p` already matches the
pointer's declared pointee type, so no further cast node is inserted,
and the interpreter itself must reinterpret the raw bits. This is
exactly cerealed's `grainReinterpret` shape: same-size pointer casts are
what it actually does, so this construction is the faithful standalone
proof, not a contrivance.

The `reinterpretLocalPointerLoad`/`floatBits`/`doubleBits` shim named in
§9.10 is deleted; these three fixtures are its ratchet and stay green
through the real native-layout reinterpret path.

**2026-07-09 follow-up: fixture rewritten as a raw pointer-slice
reproduction, Phobos `Appender` dropped.** The full-suite `bin/ut --random`
flake investigation (cross-track observation below) traced a recurring
`struct.staticArrayCopyRunsPostblitAndDtors.LLVMJit` failure to template
instances named `emplaceInitializer!(std.array.Appender!(ubyte[]).Data)`
leaking into an unrelated fixture's link set — the documented
process-global pollution class in `link-set-pollution.md`. This fixture's
`std.array.appender!(ubyte[])` instantiation was the suite's only use of
`Appender!(ubyte[])`, so it was the source. The fixture's body is now a
hand-written pointer-slice reproduction with no Phobos import:

```d
unittest {
    ubyte[] arr = [1, 2, 3, 4];
    auto shrunk = arr.ptr[0 .. 0];
    auto regrown = shrunk.ptr[0 .. 1];
    assert(regrown[0] == 1);
}
```

This distils the same construct `Appender.clear` + `put` relies on — a
pointer slice shrunk to `[0 .. 0]` must retain its backing allocation so a
regrow through `.ptr` still sees the original storage — without
instantiating Phobos' `Appender`. Applied alone at `833c560c`'s parent
(`ca901fd9`), `Interpreter` re-fails with the same diagnostic the original
proof recorded: `` pointer slice `[0..1]` exceeds allocated memory block
`[0..0]` ``; `SystemLinker` is green. Verified green at this branch's
`HEAD` on `Ctfe, Interpreter, SystemLinker, LLVMJit` (`BytecodeNewCore`
still omitted, per the existing exclusion above).

`classReferencePassedByValueMutatesObject` reproduces a class reference
passed by value to a function that mutates a field, asserting the caller
observes the mutation. Applied alone at `ca901fd9`'s parent (`bce523cc`,
"interpreter: handle emplaceRef writes" — the true parent of the
class-reference-writeback fix), `Interpreter` fails with `0 != 42` (the
caller sees the default field value instead of the callee's mutation);
`SystemLinker` is green. This fixture pins observable *behaviour*, so it
survived unchanged as `writeBackByValueClassArguments` (§9.10) was later
deleted in favor of first-class object references. Verified green at this
branch's `HEAD` on
`Ctfe, Interpreter, SystemLinker, LLVMJit`. `BytecodeNewCore` is omitted,
genuinely red: `Unsupported assignment in bytecode core: box.value = 42`
— that backend does not yet support class-field assignment at all, an
unimplemented-construct gap unrelated to this fixture's target behaviour.

Both fixtures' green matrix was re-verified on this branch's `HEAD`
(`fb92e785` plus the lazy-argument frame-capture change `674e76a2`, not
present at master when the red-first proofs above were originally run),
confirming the fix and matrix still hold with that change in place.

**Cross-track observation (2026-07-09): Phobos `Appender` instantiation
and the `bin/ut --random` flake rate.** Not owned by this plan — recorded
here per `AGENTS.md`'s cross-track rule, with a reference to
`ai/plans/link-set-pollution.md` rather than an edit to it. Full-suite
`bin/ut --random` measurements found this branch failing 3/7 runs versus
master's 0/10, always as
`ut.backends.runner.lang.structs.struct.staticArrayCopyRunsPostblitAndDtors.LLVMJit`,
with a failed-to-materialize error naming
`emplaceInitializer!(std.array.Appender!(ubyte[]).Data)` — a REPL
eval-snippet symbol unrelated to the failing test. The root cause is
`link-set-pollution.md`'s process-global DMD template-instance pollution:
some other module's instantiation of that template leaks into this
fixture's link set. `appenderClearKeepsPointerSliceBackingAllocation`'s
`std.array.appender!(ubyte[])` call was the entire `tests/` tree's only
`Appender!(ubyte[])` instantiation, so it was feeding the pollution, not
causing it. Rewriting the fixture as the raw pointer-slice reproduction
above (dropping the Phobos import) removes that instantiation, which is a
mitigation of exposure, not a fix of the root — the underlying process-
global pollution mechanism is untouched and can still be fed by some other
template instantiation elsewhere in the suite. The small-n rate
measurements (0/10, 3/7) are suggestive, not conclusive, of causation on
their own; the decisive evidence is the symbol identity in the failure
message together with this fixture being the suite's unique
`Appender!(ubyte[])` instantiator.

`emplaceRefWritesArrayElement` is the ratchet fixture: it pins the
`runEmplaceRefCall`/`isEmplaceRef` shim's behaviour for the one case
§9.10 says it is provably equivalent to real semantics — a scalar
(`char`) array element, where a plain value write is the whole of
`emplaceRef`'s job (no construction side effect to skip). Applied alone
at fix commit `bce523cc`'s parent (`7f09bd67`, the commit immediately
before "interpreter: handle emplaceRef writes"), `Interpreter` fails
with the exact diagnostic `` cannot read uninitialized variable
`.trustedMoveImpl.result` in ctfe ``; `SystemLinker` is green. Matrix
verified green at this branch's `HEAD`: `Ctfe, Interpreter, SystemLinker,
LLVMJit`. `BytecodeNewCore` is omitted for an unrelated reason: its
`_d_assert_fail` cannot render a `char[]`-vs-string-literal `==`
comparison (`Unsupported comparison assert in bytecode core:
_d_assert_fail("==", message, "ok")`), confirmed independent of
`emplaceRef` — a probe with no `emplaceRef` call at all fails
identically, and an `emplaceRef`-using probe that asserts via scalar
comparisons instead passes on `BytecodeNewCore`.

**Control-flow array truthiness.** Interpreter control-flow treats a
`Value.Array` as true exactly when its length is nonzero. This applies to
`if`, loop conditions, logical expressions, `assert`, and `?:`; explicit
`Value.castTo!bool` remains unchanged.

**`std.conv.text` character-array rendering.** The local interception renders
an operand raw when its expression type is a character array, while retaining
normal array display for non-string arrays.

**Signed-byte array reinterpretation.** A `byte[]` cast to `ubyte[]` must
preserve raw bits. Recursive aggregate boxing cannot preserve this
cast-aliasing/layout reinterpretation, so it belongs to `value.md`'s
native-layout track rather than an interpreter shim.

### 9.11 Current unconfirmed language-surface queue

These `Interpreter` omissions are implementation work. Promote each fixture
back into its `SystemLinker`-oracle matrix after fixing the named red behavior:

- `dynamicArray.reserveThenAppendWithinCapacityDoesNotReallocate`: retain the
  zero-length allocation's pointer identity across `reserve` and append.
- `pointer.comparisonWithinArray`, `pointer.relationsAcrossArraysReturnFalse`,
  and `pointer.arrayElementPostIncrementedThroughPointerIsVisibleDirectly`:
  provide the native pointer representation required by comparison and
  write-through operations.
- `pointer.slicePastAllocatedBlockDiagnostic`: decide whether the interpreter
  should retain its allocated-block diagnostic; it currently neither matches
  that characterization nor participates in the compiled-behavior row.
- `stdConvTextRendersCharArrayExpressionRaw`: keep the character array's full
  allocated block visible through the `std.array`/`std.conv.text` path.
- `refArgument.voidStructLocalFieldWritableThroughNestedRefWrite`: materialize
  the void-initialized struct before nested ref forwarding reads its field.
- `struct.staticArrayCopyRunsPostblitAndDtors`: preserve pointer fields while
  copying static-array elements before their postblits run; the current
  postblit dereferences a null counter pointer and terminates the test process.
- An interface method taking a parameter, called through an interface-typed
  variable, fails with "Unsupported interpreter call arguments." Only
  zero-arg interface methods are proven (`expressions.d`'s
  `Speaker.score()`). Found via `tests/example.d`; no matrix fixture pins
  it yet.
- A zero-arg interface method called through an interface-typed variable
  constructed directly inside a `unittest { }` block (rather than inside an
  ordinary function, as every proven matrix fixture does) silently returns
  the wrong value, with no diagnostic. Found via `tests/example.d`; no
  matrix fixture pins it yet.
- Nested-AA auto-vivification through plain index assignment
  (`int[int][int] a; a[1][2] = 3;`) fails with "Associative-array lvalue
  needs a variable" once combined with enough surrounding module content,
  despite the identical `arrays.d`
  `nestedWriteAutoVivifiesBrandNewOuterKey` fixture being `Matrix!()`-clean
  in isolation (the matrix currently records an `Interpreter` omission only
  for the compound-`+=` sibling shape). Found via `tests/example.d`; no
  matrix fixture pins the combined-content trigger yet.

## 10. Standing Cerealed regression gate

The default LDC-hosted command is green on master and must remain green:

```text
./bin/bench.sh -w 0 -r 1 -b interpreter --dub cerealed
```

Every new semantic rung keeps an approved oracle-backed,
package-independent fixture and must not regress that command. Production code
remains free of Cerealed-specific names and behavior.

## 11. Beyond cerealed

Cerealed is the first driving package, not the finish line. After the shared
formatter work, repeat the same measure, distil, approve, red-to-green loop
against a second package that exercises a different ordinary D surface. Do not
restore legacy marshalling or value machinery merely to start that next
package sooner.

## 12. Structural maintenance queue

Behaviour-preserving items; each is a ride-along for a nearby rung PR, not a
rung of its own.

- Single walk-entry owner. `Interpreter.eval`, `executeUnitTest`, and
  `evalFormattedDisplay` (`impl.d`) each repeat the same setup ritual: clear
  the frame-layout cache, fresh `ObjectTable`/`ModuleTable`, allocate the
  activation frame, close the durable inbound session on exit, catch
  `Exception` into a diagnostic. Fold the ritual into one private entry point
  taking `inUnitTest` explicitly. That owner's comment is where the walk
  preconditions belong — notably that every walk starts from a cleared
  thread-local frame-layout cache because AST arena replacement can reuse
  `FuncDeclaration` addresses across compiler lifetimes (the
  `clearFrameLayoutCache` comment is the authority).
- Cross-backend diagnostic wording moves out of
  `backends/interpreter/messages.d` one function at a time, into a
  `backends/`-level wording module, at the moment a second backend needs the
  function. The one function already shared is `uninitializedVariableMessage`
  (imported by `backends/ir/compiler.d`); it seeds the module. No new
  cross-package imports of `interpreter.messages`.

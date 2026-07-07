# Two-Backend Dub Corpus: `-b interpreter -b system-linker --dub <pkg>`

Diagnosed 2026-07-06 (four parallel investigations, each with a confirmed
minimal repro). Implemented and merged 2026-07-07 (PRs #352-#356); see
the Status section at the end for what remains live.

## Goal

```sh
bin/bench.sh -b interpreter -b system-linker --dub <pkg>
```

produces timed rows — or an honest, complete skip report — for every corpus
package. Today it fails for all four packages tried, each differently:

```text
package    exit  symptom
cerealed      1  backends disagree: __unittest_L302_C1 fails vs passes:
                 Expected array.
automem     139  SIGSEGV, all stdout lost (buffered)
tardy         0  not prepared: scope variable `t` calling non-scope member
                 function `Polymorphic.transform()` ... in a `@safe` function
fearless    139  SIGSEGV, all stdout lost (buffered)
```

Three of the four are Interpreter defects (two crashes, one wrong answer);
one is a package-resolution gap in the bench driver, not a compiler bug at
all. A cross-cutting driver problem makes every one of them worse than it
needs to be: a single backend crash or first disagreement kills the whole
run and loses the already-buffered output.

Relationship to existing plans:

- `interpreter.md` owns the Interpreter gap-closing method (§8: standalone
  red/green fixture per root cause, SystemLinker as oracle). The three
  Interpreter items below are new rungs in that sense; this document is
  their diagnosis and ordering, the fixture discipline is §8's.
- `bench.md` "Multiple `--dub` Packages Cross-Contaminate Template
  Instances" already decided fork-per-package isolation (2026-07-06). Item
  5 below notes that the same fork also contains backend crashes; it does
  not re-decide anything.

## Diagnoses

### cerealed — Interpreter: slice-assign through pointers assumes `Array`

`__unittest_L302_C1` is `cerealed/src/cerealed/scopebuffer.d:302` — the
vendored `std.internal.scopebuffer` unittest. `ScopeBuffer.put(CT[])`
grows via `realloc` and then does `buf[used .. newlen] = s[]` through the
`char*` field.

"Expected array." is quickbite's own `Value` diagnostic
(`source/quickbite/lang/package.d:636`, `Value.length`'s `match!`
catch-all). Root cause: `runSliceAssignExpression`
(`source/quickbite/backends/interpreter/impl.d:3974`) and
`runFieldSliceAssignExpression` (impl.d:4063) assume the sliced lvalue
evaluates to an `Array` Value and rebuild it via a splice loop
(impl.d:4015, :4083), then overwrite the local/field with
`Value.arrayValue(elements)`. Three distinct failure modes, each with a
confirmed repro against the disagree-checker:

1. **`NativePointer` lvalue** (realloc'd memory): `current.length` throws
   "Expected array." — the observed cerealed failure.

   ```d
   import core.stdc.stdlib: realloc;
   auto buf = cast(char*) realloc(null, 8);
   buf[0 .. 3] = "abc";   // interpreter throws; system-linker passes
   ```

2. **D `Pointer` lvalue** (e.g. `tmp.ptr`): the splice "works" but
   replaces the pointer with a plain `Array`, severing aliasing — the
   write through the pointer is silently lost (`255 != 98` divergence).
   This is a wrong answer, not a refusal, and will bite cerealed's second
   ScopeBuffer unittest (L345 `cat`) as soon as mode 1 is fixed.

3. **Sibling finding, separate class**: indexed write through a local
   pointer into a `= void` static array yields "Unsupported interpreter
   assignment target." (does not fire in the cerealed run today).

`runIndexAssignExpression` (impl.d:3846) already has exactly the branches
slice-assign lacks: `isNativePointer → storeNativePointerElement`
(impl.d:3855 → 4545) and `canWriteThroughArrayPointer →
writeThroughArrayPointer`. Fix shape: give both slice-assign functions a
pointer-typed-`e1` branch that loops those primitives
(`pointer.pointerOffsetBy(lower + i)` for D pointers) and never converts
the lvalue to an `Array`. impl.d:2319 holds a third copy of the splice
loop — audit it in the same fix.

This lands squarely on `interpreter.md` §7's `2× Expected array. →
triage` line; the silent-lost-write mode belongs with §7's "correctness
bugs in existing paths" (Rung 7 family).

### automem — Interpreter: SIGSEGV on sparse-basis `ArrayLiteralExp`

Crash phase: correctness check (`checkRunnerResults → runTests`), test
`ut.ref_counted.__unittest_L311_C9` ("theAllocator"), via
`TestAllocator`'s `private char[1024] _textBuffer;`. `char.init` is 0xFF,
so default construction goes through the struct init symbol.

DMD's `TypeSArray` default init produces the documented sparse form of
`ArrayLiteralExp` — every element null, the value carried in `basis`
(vendored dmd `typesem.d:3695-3704`; contract in `expression.d:1756`).
The interpreter's `arrayValue` (impl.d:4396-4405) iterates
`*array.elements` and calls `runExpression(element)` with no null check
and never consults `.basis`; `runExpression`'s first statement
(impl.d:859) is `expression.isIntegerExp` — a member call on null →
SIGSEGV. Nothing else in the interpreter reads `.basis`.

Minimal repro (confirmed identical backtrace):

```d
struct HasBuffer { char[16] buf; }
void makeOne() { HasBuffer b; assert(b.buf[0] == char.init); }
unittest { makeOne; }
```

Fix shape: in `arrayValue`, evaluate `element is null ? array.basis :
element` per slot — DMD's own `ArrayLiteralExp.getElement` semantics.

### fearless — Interpreter: SIGSEGV walking un-semantic'd ctor bodies

Crash phase: correctness check. fearless's `ut.concurrency` tests
evaluate `thisTid` (phobos `std/concurrency.d:426`), which executes
`thisInfo.ident = Tid(new MessageBox);`. `MessageBox` is a private phobos
class in a non-root module, so dmd never ran `semantic3` on its ctor; its
fbody is a raw parse tree with null expression types.

`runNewClassExpression` (impl.d:4962) runs the ctor body directly via
`child.runStatement(new_.member.fbody)` at impl.d:4999 **without first
calling `functionSemantic3(new_.member)`** — unlike the normal call path
(impl.d:1693-1694). Walking the raw body, `m_lock = new Mutex;`
(std/concurrency.d:2020) reaches `runNewExpression`, and impl.d:4816
(`new_.type.toBasetype`) dereferences the null type (gdb: `this == null`
in `Type::toBasetype`). `runNewStructPointerExpression` (impl.d:4899) has
the same omission — a second, latent instance.

Minimal repro (confirmed identical top frames; system-linker passes it):

```d
module thistid_repro;
unittest {
    import std.concurrency: thisTid;
    auto tid = thisTid;
}
```

Fix shape: `functionSemantic3(new_.member)` (checking for errors) before
running the ctor body, in both places. After the fix the Mutex/pthread
chain may still legitimately end in a graceful "Unsupported eval call."
skip — acceptable; process death is not. system-linker runs fearless 9/9,
so once the interpreter stops crashing the disagree-checker will report
honestly whatever gap remains.

### tardy — not a quickbite bug; `--dub` cannot reach local packages

The frontend verdict is **correct**. The registry package
(`~/.dub/packages/tardy/0.0.2/tardy`) sets, for its `unittest`
configuration, `-preview=dip25 -preview=dip1000 -preview=dip1008
-preview=in` — and real `dub test` on that same registry package fails
with the byte-identical error under dmd 2.112 (`tests/ut/polymorphic.d
(24,12)`): with `-preview=in` + dip1000, `in` is `const scope`, and the
mixin-generated `Polymorphic.transform` is not `scope`. Upstream dropped
dip1000/dip25 from the unittest dflags two commits *after* the 0.0.2
release; the local clone at `~/coding/d/tardy` (v0.0.2-2-gea967cb) is
what passes `dub test`. quickbite's flag forwarding
(`applyFrontendFlags`, `source/quickbite/frontend/compiler.d:799-861`)
reproduces dmd exactly — that fidelity is why the bench agrees with real
dmd.

The actionable gap: `findPkgDir` (`source/quickbite/dub.d:163-202`) scans
only the registry cache (`~/.dub/packages`, fetching on a miss, highest
version wins). It can never resolve the checkout the user actually
tests. Fix direction, smallest first:

1. **Accept a path for `--dub`**: in `resolveDubPkg`
   (`benchmarks/cli.d:546`), if the argument is an existing directory
   containing a dub recipe, use it as `pkgDir` directly, skipping
   `findPkgDir`. `bin/bench.sh ... --dub ~/coding/d/tardy` then benches
   the same instance `dub test` ran in. No behaviour change for names.
2. (Optional, later, data-gated) teach `findPkgDir` about
   dub-registered local packages via `dub list`. Today `dub list` shows
   only the registry 0.0.2, so option 1 is what actually unblocks tardy.

Secondary paper cut: the preparation note drops the diagnostic's
file:line (`tests/ut/polymorphic.d(24,12)`), which is what made this look
like a quickbite semantics bug. Keep the location in the note.

## Cross-cutting: the driver dies with the first casualty

Two independent amplifiers turned four ordinary findings into "bench
doesn't work":

- **A backend SIGSEGV kills the driver and loses buffered stdout** — the
  automem/fearless runs printed nothing, not even the preparation
  section that had already succeeded. The fork-per-package isolation
  already decided in `bench.md` (children run each package's whole
  pipeline; parent renders from piped results) contains crashes for
  free: a dead child becomes a reported per-package failure instead of a
  dead bench. No new decision needed here — only a note that crash
  containment is now a second motivation for that work. Independent
  quick win regardless: flush stdout after the preparation section.
- **The disagree-check aborts the whole run on the first mismatch**
  (`checkRunnerResults` throws, `cli.d:351-357`). For gap-closing work
  the useful output is the *full* per-test disagreement list —
  `interpreter.md` §6 already wants a permanent `--list-failures` mode
  in place of its throwaway probe. Report all mismatches for the unit,
  skip that unit's timing, continue with other units/packages.

## Work items, in order

Ordering: wrong answers and crashes first (they poison trust in every
other row), then reach, then reporting. Every item follows the TDD /
approval rules at the end of this document: tests written first,
confirmed red for the documented reason, then made green, on the widest
backend matrix the fixture can express.

### 1. Interpreter: sparse-basis `ArrayLiteralExp` (automem crash)

Smallest fix, clear contract violation, unblocks automem entirely (its
system-linker run already completes). Exposing test first
(pre-approved): backend-matrix `ct/` fixture, SystemLinker oracle —

```d
struct HasBuffer { char[16] buf; }
unittest {
    HasBuffer b;
    assert(b.buf[0] == char.init);
    assert(b.buf[15] == char.init);
}
```

Red on Interpreter today (SIGSEGV — which is itself the finding), green
on SystemLinker/Ctfe. Then fix `arrayValue` to use `basis` for null
elements.

### 2. Interpreter: `functionSemantic3` before ctor-body walks (fearless crash)

Exposing test first (pre-approved): the `thisTid` fixture above,
`rt/` (needs pthreads/libc), SystemLinker oracle, asserting the
interpreter either matches the oracle or raises its structured
unsupported-diagnostic — never dies. Fix both `runNewClassExpression`
and `runNewStructPointerExpression`. Re-run fearless: expect either
timed rows or honest skips/disagreements.

### 3. Interpreter: pointer slice-assign (cerealed disagreement)

Three fixtures (pre-approved), each pinning one mode:

- `rt/cstdlib.d` (existing `reallocNullSource` style): realloc'd
  `char*`, `buf[0 .. 3] = "abc"`, assert the bytes — red mode 1.
- `ct/`-expressible D-pointer fixture: `char[8] tmp; auto p = tmp.ptr;
  p[2 .. 5] = "abc"; assert(tmp[3] == 'b');` — red mode 2 (silent lost
  write; the more dangerous bug).
- Separate fixture for the `= void` "Unsupported interpreter assignment
  target." class — its own finding, own rung.

Fix per the `runIndexAssignExpression` pattern; audit the impl.d:2319
splice copy. Bookkeeping: fold these into `interpreter.md` §7 (the
`Expected array.` and Rung 7 lines) when the rungs are worked, so the
inventory stays the single Interpreter gap ledger.

### 4. Bench driver: path-accepting `--dub` (tardy)

Exposing test (pre-approved): resolve a minimal sandbox dub package
by absolute path — today `findPkgDir` throws "could not find package";
green when a recipe-bearing directory is used as `pkgDir` directly.
Include the frontend diagnostic's file:line in the preparation note
while in the area. tardy-the-registry-package stays legitimately
unpreparable — that is the correct verdict; the corpus entry becomes the
local clone by path (or upstream tags a release and the registry catches
up).

### 5. Bench driver: survive per-unit failure, report fully

- Full mismatch list per unit (the `--list-failures` mode
  `interpreter.md` §6 asks for) instead of first-mismatch abort; skip
  the unit's timing, keep going.
- Crash containment rides on `bench.md`'s fork-per-package item (its
  implementation, not this plan's); until it lands, flush stdout after
  the preparation section so a later crash cannot eat it.

## Verification

After items 1-3 (each individually, plus at the end):

```sh
ninja bin/ut && bin/ut --random
bin/bench.sh -b interpreter -b system-linker --dub automem    # rows, no segv
bin/bench.sh -b interpreter -b system-linker --dub fearless   # no segv
bin/bench.sh -b interpreter -b system-linker --dub cerealed   # past L302;
                                                # remaining gaps per §7 ledger
```

After item 4:

```sh
bin/bench.sh -b interpreter -b system-linker --dub ~/coding/d/tardy
```

cerealed is not expected to go fully green from item 3 alone —
`interpreter.md` §7 lists 91 failing unittests across more classes; this
plan clears the specific disagreement the two-backend run trips on first
and the two packages that cannot run at all.

## TDD / approval

Strict red-first, per AGENTS.md, and non-negotiable for every item:

1. The implementer first writes the exposing unit tests and **runs them,
   confirming each one fails — and fails for the documented reason**
   (SIGSEGV, "Expected array.", the silently lost write, the resolution
   throw) — before writing any fix code. A test that is green from birth
   or red for a different reason pins nothing; stop and rediagnose.
2. Only then make them pass, dumbest code first, and finish with a green
   `ninja bin/ut && bin/ut --random`.
3. **The exposing tests in this plan are pre-approved** (user,
   2026-07-06): AGENTS.md's stop-for-approval rule is waived for them.
   The waiver holds on two conditions, one per side of the fix:
   - **red as expected before**: each test is confirmed to fail in the
     expected manner (rule 1);
   - **green as expected after**: each test turns green — on the
     backend the item targets (here always `Interpreter`, plus the
     driver for item 4) — when the implementer applies the fix they
     believe correct. Other matrix backends may keep a documented red,
     per the matrix rules below.
   A test that fails differently, is green from birth, or stays red
   after the intended fix is outside the waiver: stop and ask rather
   than reshaping the test or the fix to force agreement. Tests beyond
   this plan's scope still need approval as usual.

**Backend matrix: as wide as each fixture can express.** These are
language-surface tests, so they follow the existing promotion rule
(every backend except `Ctfe` is a promotion candidate, SystemLinker is
the oracle):

- `ct/` fixtures (items 1 and the D-pointer/`= void` fixtures of item 3)
  run under the full `static foreach (backend; AliasSeq!(Ctfe,
  Interpreter, BytecodeNewCore, SystemLinker, LLVMJit))` matrix. Where
  `Ctfe` legitimately diverges, pin its actual behaviour as a
  characterization test with a comment naming the divergence — never
  narrow the matrix to dodge it.
- `rt/` fixtures (item 2's `thisTid`, item 3's realloc slice-assign) run
  on every backend with runtime-environment support — today
  `Interpreter`, `SystemLinker`, `LLVMJit` — again with SystemLinker as
  oracle.
- A backend for which the fixture stays red after the item's fix keeps
  its red documented (structured unsupported-diagnostic expectation, as
  the existing `ct/`/`rt/` conventions do), rather than being dropped
  from the matrix.

The minimal repros above were all confirmed against the live
disagree-checker on 2026-07-06; sources preserved in the session
scratchpad and inlined here so they survive it.

## Status (2026-07-07): all five items implemented and merged

```text
#352  item 1  sparse-basis ArrayLiteralExp          merged
#353  item 2  functionSemantic3 before ctor walks   merged
#354  item 3  pointer slice-assign                  merged
#355  item 4  path-accepting --dub + file:line note merged
#356  item 5  full mismatch list + stdout flush     merged
```

This plan's work items are done. What remains live in this document is
the two sections below: the support-not-refusal goal for the surviving
interpreter gaps, and the infra/template/linker issues that need their
own plan.

Verification state on merged master: automem prepares 14/14, no SIGSEGV,
and the full disagreement list shows 14 mismatches — 12×
`Unsupported eval expression: address of call`, 1×
`Unsupported binary lhs type.`, 1× silent `false != true` — then the
run continues instead of dying. fearless prepares 7/7,
`address of dotVariable` (`__unittest_L33_C7`). cerealed prepares 32/32,
past `Expected array.`; L302 now fails deeper (`[ , a] != "xa"`, the
ScopeBuffer realloc/memcpy family). tardy by path prepares 22/22 and
times the frontend on the interpreter leg, while the system-linker leg
crashes (below); by registry name it stays correctly unpreparable with
the located note `ut/polymorphic.d(24,12): scope variable ...`.

### The goal is support, not pinned refusal

Item 2's exposing fixture (`rt/concurrency.d`, `thisTid`) currently lets
the Interpreter leg pass on *either* oracle agreement *or* a structured
unsupported diagnostic. That acceptance was crash-scoped triage — the
item's target was "never dies" — not the end state. The goal is that the
interpreter **runs** these constructs and agrees with `SystemLinker`:
here, and for the surviving disagreements above (`address of call`,
`address of dotVariable`, the ScopeBuffer family). Do not add further
tests that pin an unsupported diagnostic as acceptable interpreter
behaviour; distil each gap into a red/green fixture per `interpreter.md`
§8 and fix the root, folding results into the §7 ledger.

**2026-07-07 update:** the `address of call` class is fixed (address of
a ref-returning call; fixtures
`pointer.addressOfRefReturningCallAliasesArgument` and
`pointer.refTernaryReturnLowersToAddressOfCall` in ct/expressions).
automem and fearless now run `theAllocator`'s real initialization and
stop honestly at the next rungs (`pthread_mutexattr_init` FFI,
`trustedMoveImpl` uninitialized reads, `assignment target: call`,
`cast_`); details in the §7 ledger entry of the same date.

### Infra/template/linker issues discovered (need their own plan)

Found while implementing; none are fixed by this plan's items. Another
agent should plan these.

1. **Template-instance pollution flakes the native backends' oracle
   legs.** `concurrency.thisTid.SystemLinker`/`.LLVMJit` fail in roughly
   a third of full-suite `bin/ut --random` runs: the emitted object
   references phobos template instances (`MapResult`/`FilterResult`)
   whose template arguments are *REPL-eval snippet lambdas* from other
   tests. Observed: the fixture's own `snippet_98` object referencing
   `snippet_274__quickbite_repl_eval` instances — an instance created
   *after* the fixture was parsed, adopted into its link set at codegen
   time. SystemLinker leg dies as a mold undefined-symbol link failure;
   LLVMJit as JITLink failed-to-materialize. Not seed-reproducible
   (both failing seeds pass on rerun) — the `ai/mistakes.md`
   scapegoat-root-module pollution class ("flaky-seed repros",
   process-global `importedFrom`/allInst state). `std.concurrency` is
   the heaviest phobos link surface in the suite and shares
   `iota`/`map`/`filter`/`Appender` instantiations with the REPL eval
   tests, so this fixture is currently the best repro driver. Evidence
   and occurrence log in PR #353's comments.
2. **tardy crashes the system-linker run executor.**
   `bin/bench.sh -b system-linker --dub ~/coding/d/tardy` (reachable
   only since item 4) prepares 22/22, links the dependency image, then
   the run executor exits with status -11. First-ever run of this
   configuration, so a discovery, not a regression. Needs its own
   diagnosis and an exposing unit test per AGENTS.md.
3. **The bare-`ninja` `bin/bench` target is misconfigured**: it passes
   the LDC-only flag `-link-defaultlib-shared` to `/usr/sbin/dmd` and
   fails to build. Pre-existing reggae build-config quirk; the required
   gates (`ninja bin/ut`, `bin/ut --random`, `ci.sh`) are unaffected.

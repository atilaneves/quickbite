# Template-Instance Pollution Flakes The Native Backends' Oracle Legs

Status: **planned** (2026-07-09, diagnosis-first) — mechanism research
done, escape path not yet identified. Finding recorded 2026-07-07
during the two-backend dub corpus work, PR #353. Nothing here is
implemented; rung 0 is the next action.

## Symptom

`concurrency.thisTid.SystemLinker` and `.LLVMJit` fail in roughly a third
of full-suite `bin/ut --random` runs:

```text
SystemLinker  mold undefined-symbol link failure
LLVMJit       JITLink failed-to-materialize
```

The emitted object for the fixture references phobos template instances
(`MapResult`/`FilterResult`) whose template arguments are *REPL-eval
snippet lambdas from other tests*. Observed concretely: the fixture's own
`snippet_98` object referencing `snippet_274__quickbite_repl_eval`
instances — an instance created *after* the fixture was parsed, adopted
into its link set at codegen time.

Not seed-reproducible: failing seeds pass on rerun. Occurrence log in
PR #353's comments. A second, independently observed driver:
`random.unpredictableSeedReadsNonRootInitializer.SystemLinker` (PR #394's
comments; `std.random`, another heavy phobos link surface) — so
`concurrency.thisTid` is the best-known driver, not the only one. Do not
conflate with the LLVMJit Delta32/`DW.ref.__dmd_personality_v0` flake:
that one was codegen-deterministic and is fixed (PR #394, `orc/elf.d`).

## Mechanism (established 2026-07-09, code research)

The pollution channel, confirmed end to end:

1. Every snippet ever parsed — REPL evals included — registers a root
   module in DMD's process-global `Module.amodules` and stays there for
   the life of the `bin/ut` process. Nothing resets parse/semantic state
   between tests; the codegen fork (`runInFork`,
   `source/quickbite/backends/native/codegen.d:249`) isolates the DMD
   *backend* only.
2. Native codegen is lazy: it runs when the owning unittest *executes*
   (`--random`-scheduled), not when the fixture parses. Inside the fork
   child, `adoptOrphans` (`codegen.d:424`, called at `codegen.d:212`)
   scans the entire `Module.amodules` table for template instances homed
   on out-of-link root modules and adopts any that pass
   `instanceIsForeign` onto the lightning rod. What a fixture's link
   adopts therefore depends on every test that happened to run earlier
   in that shuffle.
3. Instances land on foreign modules in the first place because of DMD
   first-root-homing: `appendToModuleMember` (dmd `templatesem.d:1225`)
   homes an instance on the declaring module's `importedFrom`, which is
   set once per process, first importer wins (`dsymbolsem.d:7665`).
   Same class as bench.md "Multiple `--dub` Packages Cross-Contaminate
   Template Instances" and dub-deps.md "Open: per-fixture completeness".

Key facts that constrain the fix:

- **The gate is purely structural.** `instanceIsForeign` /
  `argIsForeign` / `symbolIsForeign` (`codegen.d:574-682`) judge by
  module membership of tiargs, parents, and declaring modules. No
  ordering signal exists anywhere: the `snippet_<N>` counter
  (`compiler.d:25`) is discarded into a filename string; DMD's
  `TemplateInstance` carries `minst`/`memberOf`/`tinst` (structural),
  never a sequence number.
- **The observed shape should already be rejected.** `argIsForeign`'s
  `FuncExp` branch (`codegen.d:609-618`) exists precisely to judge a
  lambda alias argument by where the function symbol lives, and
  `moduleIsForeign` returns foreign for another snippet's module. Yet
  PR #353 shows a `MapResult!(other-snippet lambda)` escaping. So the
  real escape path is an *unknown gap*, not a missing gate. Leading
  suspect (dmd-backend.md lessons 13/16): an instance whose arguments
  look innocent but whose *body* references foreign symbols — invisible
  to any arg walk.
- **An ordering gate alone cannot be the fix.** The original next-steps
  sketch ("refuse instances first-instantiated after the fixture's
  parse") covers only the PR #353 shape; an instance homed on an
  *earlier*-parsed snippet is equally unresolvable at link time. Parse
  order is at most a supplementary signal.
- **Why fixed seeds don't reproduce:** the adopt/prune machinery keys
  AAs on AST node pointers (`bool[Module]`, `bool[TemplateInstance]`,
  `codegen.d:191`, `codegen.d:395`), whose iteration order varies with
  ASLR per process launch; `GC.collect` after every native leg
  (`system_linker.d:91`) adds conservative-GC layout sensitivity.
  PR #394 established the same-seed-different-outcome precedent. The
  adoption fixed point iterates a plain array, so *membership* is
  plausibly order-independent — verify, don't assume (rung 0).
- **Fix must precede object emission.** `codegen.d` is shared by
  SystemLinker and LLVMJit (extracted at `9d09e4f4`); fixing there fixes
  both legs, per single-oracle.md.
- **Loose end — rod never imports `std`:** dmd-backend.md lesson 20
  records a "verified fix" (lightning rod does `import std;` so phobos
  modules pin `importedFrom = rod` at process init) and a decision to
  land it, but the checked-in rod (`compiler.d:314`) is still the bare
  empty module and git history shows no landing or revert. Investigated
  in rung 3.

## Plan

Diagnosis-first: the escape path contradicts the code as read, so no
fix seam is chosen until rung 0 produces evidence. Scope is this flake
class only — in-process `bin/ut` link-set pollution at the adoption
seam. dub-deps.md "per-fixture completeness" shares the root cause but
stays its own item; cross-reference, don't absorb.

### Rung 0 — controlled repro + instrumentation (no behaviour change)

Stop chasing full-suite `--random` seeds. Two deterministic-ordering
levers exist (verified empirically):

- Positional args filter but never reorder; execution is alphabetical
  by test path. So an eval test that sorts before the fixture runs
  first with no seed at all:

  ```sh
  bin/ut "ut.backends.evaluator.eval.literal.SystemLinker" \
         "ut.backends.runner.sys.concurrency.concurrency.thisTid.SystemLinker"
  ```

- `tests/ut/bin/repl.d` tests (the `map!`/`filter!`/`iota` REPL evals)
  sort *after* the fixture; force the order with a two-test `--random`
  and a trivial seed search (two orderings total).

A single ordered run did not fail — consistent with layout-dependent
intermittency — so the repro is a *looped* ordered run plus temporary
instrumentation in `adoptOrphans`: log every adopted candidate and
which branch of the `instanceIsForeign` chain returned not-foreign for
it (and, on a failing link, the undefined symbol). Widen the snippet
pool (several repl.d/evaluator tests before the fixture, both drivers)
until a failure is captured.

Exit criterion: the exact escaping AST shape is named, with evidence —
the adopted instance, its homing module, and the verdict path that let
it through. Findings get appended here; the instrumentation itself does
not land.

Fallback if the loop won't fail under controlled ordering: run the
instrumentation (log-only) under full-suite `--random` until the flake
fires there — the diagnosis needs one instrumented failure, wherever it
comes from.

### Rung 1 — deterministic exposing test (approval required)

Per AGENTS.md, a test design goes to the user for approval before any
fix. Shape it from rung 0's diagnosed escape, in the mould of
`tests/ut/backends/runner/lang/pollution.d` (the existing
stale-parse-ordering regression test): parse a snippet crafted to
produce the escaping shape, then compile a second fixture whose link
must not adopt it — asserted either end-to-end (the link succeeds and
the emitted object is clean) or directly (adoption of an instance homed
on an out-of-link snippet module is refused). The test must fail
reliably pre-fix; if the diagnosed shape turns out to be inherently
layout-dependent end-to-end, assert at the adoption decision itself,
where the verdict is deterministic given the crafted AST.

### Rung 2 — fix at the evidenced seam (decision gate)

Chosen only after rung 0. Candidate seams, mapped with what data each
has:

- **Tighten the structural gate** (`instanceIsForeign` family): if the
  escape is a reachable-but-unvisited AST edge (e.g. body references,
  default args, context pointers not present in `tiargs`), extend the
  walk or flip the default for instances homed on out-of-link *snippet*
  root modules (the rod and archive modules stay adoptable). Precedent:
  `ai/mistakes.md`'s `prepareArchiveImportsForTemplateCodegen` fix —
  derive codegen decisions from actual membership, not heuristics.
- **Reference-driven adoption** (dub-deps.md sketch): decide adoption
  from the emitted object's actual undefined symbols (a link-level
  fixpoint) instead of AST walks — immune to any shape the walk misses.
  Reach for this only if rung 0 shows the shape cannot be closed
  structurally; it is the bigger design and overlaps the out-of-scope
  per-fixture-completeness item.

Either way the fix lands in shared `codegen.d` (both backends), gated
by rung 1's test, validated by rung 4.

### Rung 3 — lightning-rod `import std;` (lesson 20 discrepancy)

Establish why the recorded "verified fix" never landed (git archaeology
plus a trial: rod init cost, semantic failure, or simply dropped), then
land it or formally reject it with the reason recorded in
dmd-backend.md. If landed, phobos modules pin `importedFrom = rod` at
init and snippets can no longer claim phobos-homed instances — a large
surface shrink for this flake, but not the fix: instances homed on
snippet modules themselves (nested/capturing lambdas) remain, so rung 2
still stands. Ordered after rung 2 so the fix is validated against the
unshrunk surface.

### Rung 4 — statistical acceptance

The in-suite test (rung 1) pins the diagnosed shape; the field flake is
layout-dependent, so acceptance is the `ai/mistakes.md` technique:
repeated full-suite `bin/ut --random` runs on baseline vs fixed builds,
comparing failure counts of both driver tests (`concurrency.thisTid`,
`unpredictableSeedReadsNonRootInitializer` native legs), not a single
shared seed. Baseline incidence for calibration: PR #353 logged 3
flaked runs in ~9; PR #394 estimated ~1-in-32 for the second driver.

## Relationship to existing work

- `interpreter.md` §9.8 landed `adoptOrphans` (adopt-then-prune at native
  codegen, provenance-gated) — the mechanism under diagnosis here.
- `bench.md` "Multiple `--dub` Packages Cross-Contaminate Template
  Instances" is the same root-cause *class* across bench packages; its
  decided fix (fork-per-package) isolates bench runs but does nothing for
  in-process `bin/ut` test ordering, which is this document's territory.
- `dub-deps.md` "Open: per-fixture completeness" shares the
  first-root-homing root cause within a single package; its
  reference-driven sketch is rung 2's second candidate but the item
  itself stays separate.
- `dmd-backend.md` lessons 13/16 (arg-walk blindness to instance
  bodies), 17/20 (rod scope and the unlanded `import std;`), 19 (CTFE
  mutates homing state in the parent, unprotected by the codegen fork).

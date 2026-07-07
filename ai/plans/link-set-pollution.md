# Template-Instance Pollution Flakes The Native Backends' Oracle Legs

Status: **needs a plan** — this document records the finding (2026-07-07,
discovered during the two-backend dub corpus work, PR #353) so an agent can
diagnose and plan the fix. Nothing here is implemented.

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

Not seed-reproducible: failing seeds pass on rerun. That signature places
it in the `ai/mistakes.md` scapegoat-root-module pollution class
("flaky-seed repros"): process-global DMD state (`importedFrom`,
`allInst`) shared across tests in one `bin/ut` process.

## Why this fixture is the repro driver

`std.concurrency` is the heaviest phobos link surface in the suite and
shares `iota`/`map`/`filter`/`Appender` instantiations with the REPL eval
tests, so `concurrency.thisTid` is currently the best-known driver.
Evidence and an occurrence log are in PR #353's comments.

## Relationship to existing work

- `interpreter.md` §9.8 landed `adoptOrphans` (adopt-then-prune at native
  codegen, provenance-gated) — the mechanism whose gating this flake
  implicates: an instance created after the fixture's parse is being
  adopted into the fixture's link set.
- `bench.md` "Multiple `--dub` Packages Cross-Contaminate Template
  Instances" is the same root-cause *class* across bench packages; its
  decided fix (fork-per-package) isolates bench runs but does nothing for
  in-process `bin/ut` test ordering, which is this document's territory.
- `dub-deps.md` "Open: per-fixture completeness" shares the
  first-root-homing root cause within a single package.

## Next steps (for the planning agent)

1. Reproduce under a controlled two-test ordering (a REPL-eval test before
   `concurrency.thisTid`) instead of chasing `--random` seeds.
2. Decide the seam: tighten `adoptOrphans`' provenance gate (e.g. refuse
   instances first-instantiated after the fixture's parse), or isolate the
   polluting state per test. An exposing unit test per `AGENTS.md`
   (approval required) must precede any fix.

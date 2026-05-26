# Resolve PR 42 Unresolved Review Threads Locally

## Summary

Create a fresh post-merge branch/worktree named `refactor-after-42` from
`master` at merge commit `a46a571`. Use the existing PR 42 handoff plan and a
fresh read-only GitHub thread refresh as coordination input, but do not post
GitHub replies or resolve GitHub threads.

All 21 unresolved review threads are in scope. Design-question threads must
stop for an explicit owner decision before code changes. Threads without
reviewer-supplied tests must follow strict TDD and ask before adding or
modifying tests.

This plan is local coordination state unless explicitly requested otherwise.

## Coordination

- Create worktree: `worktrees/refactor-after-42`, branch
  `refactor-after-42`, based on current `master`.
- Keep any ongoing coordination notes under `ai/plans/`, marked local-only and
  not staged unless explicitly requested.
- Before assigning work, refresh PR 42 review threads with GitHub GraphQL and
  reconcile against the 21-thread list from the research report.
- Run one worker subagent per review thread, serially, using a separate worker
  worktree for each code-changing task.
- After each worker result: inspect changes, integrate only accepted patches,
  run focused verification, then continue to the next thread.
- Do not touch GitHub thread resolution state; record local status only.

## Work Items

### Bytecode

- `r3302151178`: ask owner whether bytecode binary operations beyond integers
  are required here or should remain follow-up scope.
- `r3302156271`: ask owner for the intended `Instruction` operand model before
  changing constructors or `long`/`Value` use.

### IR Alias And Scalar Execution

- `r3302162744`: address or decide array alias key representation instead of
  storing indexes as `Value(cast(long) index)`.
- `r3302163646` and `r3302164396`: treat slice lower-bound storage and nested
  slice `asLong` offset handling as one inseparable alias-key task.
- `r3302168539`: ask whether integer casting is intentional IR semantics or
  should be represented differently before changing `castInteger`.
- `r3302176674`: inspect current binary-op lowering/execution and either prove
  the outdated concern is already fixed or propose the exact remaining
  numeric-behavior test for approval.
- `r3302181461`: add a dedicated "not implemented yet" exception type only if
  it can be done without changing public diagnostics unexpectedly.

### Frontend Lowering And IR Bitcasts

- `r3302198764`: refactor the address-of/pointer lowering shape to remove the
  arrow anti-pattern if behavior stays unchanged.
- `r3302200930`: ask owner whether the named helper should be renamed, removed,
  or folded into a clearer abstraction.
- `r3302204339`: clarify the real-literal runtime-value helper through naming
  or structure, with no behavior change unless a test is approved.
- `r3302208623`, `r3302215722`, and `r3302228078`: treat IR bitcast operation
  placement and duplicated float-bit helper code as a design cluster; ask owner
  where the conversion responsibility belongs before editing.
- `r3302211950`: simplify unsigned-type helper shape if inspection confirms the
  helper is unnecessary.

### `Value` Design

- `r3302218494`: ask owner whether `Value` should continue wrapping `SumType`,
  expose it differently, or become a direct alias/API.
- `r3302223189`: inspect `SumType` query support, then replace redundant
  helper(s) only after confirming the API shape.
- `r3302226040`: fix array truthiness if reachable behavior exists; otherwise
  document why the code is dead or unreachable before changing it.

### Tests

- `r3302230514`: ask whether the cerealed float round-trip coverage belongs in
  this follow-up, another PR, or should remain as historical regression
  coverage.
- `r3302232721`: clarify or rename the function-pointer ID test only after
  confirming its intended public behavior.
- `r3302235352`: verify whether the outdated scalar value type test has already
  moved; if not, ask before moving or expanding coverage.

## Test Plan

- For existing reviewer-supplied probes, use the named tests from the PR 42
  handoff where relevant.
- For every new behavior test not supplied by the reviewer, stop and ask for
  approval before editing tests.
- For behavior-changing code: run the new/affected focused test first red, then
  green after implementation.
- For pure refactors: run the closest existing focused tests for the touched
  subsystem.
- After each accepted worker integration, run focused verification.
- After the editing session, run `dub test`.
- Before any PR from `refactor-after-42`, run `benchmarks/run.sh`.

## Confirmed Defaults

- Branch/worktree name: `refactor-after-42`.
- Scope: all 21 unresolved threads.
- Design threads: ask owner first; workers must not choose design defaults.
- GitHub handling: local only; do not reply to or resolve GitHub threads.
- Test policy: ask per unsupplied test, preserving strict TDD.

# Ctfe Backend Pure Test Migration Plan

## Summary

Migrate existing `tests/ut/executors/pure_` coverage to Ctfe backend tests one
executor test at a time. The migration converts executor unittest fixtures into
D-feature-based backend checks, with a reviewer subagent reviewing each
conversion before implementation.

Use branch/worktree `ctfe-pure-backend-tests` at
`worktrees/ctfe-pure-backend-tests`. Use one shared slice worktree for the main
agent and subagents. Land one commit per migrated executor test.

## Key Changes

- Treat existing backend `eval.d` coverage as complete.
- Do not add backend `runTests`, `runTestSummary`, unittest-count APIs, or
  assertion-message parity.
- Add eval-style Ctfe backend tests under `tests/ut/backends/pure_`, using
  `newBackend!Ctfe.eval(...)`.
- Convert executor fixtures to language-result checks:
  - `assert(x == expected)` becomes eval returning `x`, compared to
    `Value(expected)`.
  - Mutation/control-flow tests return the final observable value.
  - Struct tests return a field or derived scalar/array value.
  - Exception tests return a catch result or message string when that is the D
    feature under test.
  - Diagnostic/unittest-failure tests keep only the underlying D feature
    behavior.
- If a migrated test passes immediately, temporarily invert the expected value
  to prove the test can fail, then restore and commit only the real test.

## Required Review Gates

Before adding each converted backend test, spawn a reviewer subagent to review
only the proposed conversion from executor test to D-feature backend test.

The conversion reviewer must check that:

- The converted test still covers the same D language feature.
- No important behavior was lost by removing `unittest`/`assert`.
- The eval expression has a clear observable result.
- Runtime-shaped fixtures still avoid accidental constant folding.
- The conversion does not introduce unittest mechanics, assertion-message
  checks, or backend API expansion.

After implementation, spawn or reuse a reviewer subagent to review the
production change before committing.

## Workflow Per Test

1. Pick the next unmigrated executor pure test in source order.
2. Draft the eval-based Ctfe backend conversion.
3. Spawn a reviewer subagent to review the conversion only.
4. Present conversion-review findings one by one for user approval.
5. After approval, add the backend test.
6. Run the focused test:
   - If it fails for a real Ctfe language gap, keep that as the TDD red step.
   - If it passes, run the temporary negative probe, restore it, and treat Ctfe
     support as already present.
7. For a red Ctfe gap, spawn an implementer subagent with bounded ownership of
   the needed production files.
8. Run the focused test, then `dub test`.
9. Spawn or reuse a reviewer subagent to review the implementation slice.
10. Present implementation-review findings one by one; apply only approved
    fixes.
11. Repeat implementer/reviewer until no review comments remain.
12. Commit the completed migrated test and implementation as one commit.
13. Continue with the next executor test until the orchestrator decides the
    session has reached one PR worth of work.

## PR Boundary

The orchestrator must stop after one PR-sized batch, using judgment rather than
a fixed number. Default signals to stop and create a PR:

- The batch contains several completed commits and a coherent language-feature
  theme.
- The diff is large enough that adding more tests would make review harder.
- A natural file or feature boundary has been reached.
- The next migrated test would require a substantially different Ctfe feature.
- Review/implementation loops are getting long enough that the current work
  should land independently.

At that point:

- Run `dub test`.
- Ensure all review comments are resolved.
- Push the branch.
- Create a PR.
- Open the PR in the browser, following repo instructions.
- Do not start the next PR's work in the same agent session.

## Migration Order

1. `expressions.d`
2. `logic.d`
3. `control_flow.d`
4. `arrays.d`
5. `structs.d`
6. `exceptions.d`
7. `diagnostics.d`
8. `math.d`
9. `minicereal.d`
10. `projects/cerealed.d`

## Test Plan

- Run the focused unit-threaded test after adding each backend test.
- Run a temporary negative probe for already-passing migrated tests, then
  restore it.
- Run `dub test` after every implementation/review cycle and before each
  commit.
- Before each commit, confirm the backend test is eval-based, conversion review
  happened, no backend unittest API was added, probes are gone, and `dub test`
  passes.

## Assumptions

- Scope includes all current `tests/ut/executors/pure_` tests, including
  minicereal and cerealed project-inspired tests.
- Existing backend `eval.d` migration is accepted as complete.
- One commit per migrated executor test.
- Shared slice worktree for main agent, implementer, and reviewer subagents.
- Public backend API changes are out of scope.

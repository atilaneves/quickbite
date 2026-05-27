# Ctfe Backend Pure Test Migration Plan

## Summary

Migrate existing `tests/ut/executors/pure_` coverage to Ctfe backend tests one
executor test at a time. The migration keeps fixtures as valid D unittest
modules.

Use branch/worktree `ctfe-pure-backend-tests` at
`worktrees/ctfe-pure-backend-tests`. Use one shared slice worktree for the main
agent and subagents. Land one commit per migrated executor test.

## Key Changes

- Treat existing backend `eval.d` coverage as complete.
- Add unittest-style Ctfe backend tests under `tests/ut/backends/pure_`, using
  valid D source that contains `unittest` blocks.
- Do not convert unittest fixtures into REPL-only snippets that are not valid D.
- Each migrated positive test needs a matching negative assertion probe. Passing
  unittests do not print or throw, so the negative probe proves the unittest ran
  and exposes the observed value through the failure diagnostic.
- All negative assertion probes must check `-checkaction=context`-style failure
  messages. Always verify the actual CTFE engine output for the failing
  assertion before encoding the expected diagnostic.
- Convert executor fixtures by preserving the D language behavior:
  - Keep `unittest` blocks and assertions in the backend source.
  - For `assert(x == expected)`, keep the positive assertion and add a negative
    probe that makes the same observable value fail.
  - Mutation/control-flow tests assert the final observable value.
  - Struct tests assert a field or derived scalar/array value.
  - Exception tests assert the catch result or message string when that is the D
    feature under test.
  - Diagnostic/unittest-failure tests keep only the underlying D feature
    behavior unless the diagnostic itself is the behavior under migration.
- If a migrated positive test passes immediately, keep it as already-supported
  behavior only after the negative probe has failed with the verified CTFE
  diagnostic.

## Review Gates

Before adding a converted backend test, use judgment on whether a conversion
reviewer is useful. Source-preserving migrations that keep the same valid-D
fixture and add only the required negative diagnostic probe do not need a
separate conversion reviewer.

When used, the conversion reviewer must check that:

- The converted test still covers the same D language feature.
- No important behavior was lost while moving to Ctfe backend coverage.
- The source remains valid D.
- The positive unittest has a clear observable assertion.
- The negative probe verifies the same observable value with a
  `-checkaction=context`-style diagnostic checked against real CTFE output.
- Runtime-shaped fixtures still avoid accidental constant folding.
- The conversion does not introduce unrelated backend API expansion.

After implementation, spawn or reuse a reviewer subagent to review the
production change before committing.

## Workflow Per Test

1. Pick the next unmigrated executor pure test in source order.
2. Draft the unittest-style Ctfe backend conversion and the matching negative
   probe.
3. Verify the actual CTFE engine diagnostic for the negative assertion.
4. Present the exact proposed test or diff for user approval before editing
   tests; include conversion-review findings only when a reviewer was used.
5. After approval, add the backend test.
6. Run the focused test:
   - If it fails for a real Ctfe language gap, keep that as the TDD red step.
   - If it passes, treat Ctfe support as already present because the negative
     probe already proved the assertion path.
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
- Verify every negative assertion diagnostic against the actual CTFE engine
  output before encoding the expected message.
- Run `dub test` after every implementation/review cycle and before each
  commit.
- Before each commit, confirm the backend test is valid-D unittest source,
  any needed conversion review happened, negative diagnostics use verified
  `-checkaction=context`-style messages, no temporary probes are left, and
  `dub test` passes.

## Assumptions

- Scope includes all current `tests/ut/executors/pure_` tests, including
  minicereal and cerealed project-inspired tests.
- Existing backend `eval.d` migration is accepted as complete.
- One commit per migrated executor test.
- Shared slice worktree for main agent, implementer, and reviewer subagents.

## Handoff Status

Branch `ctfe-pure-backend-tests` contains the first migration commit candidate:
`expressions.d` / `intAddition`.

Implemented in this slice:

- Added backend-level `runTests(in string source)`.
- Implemented `Ctfe.runTests` for valid-D unittest fixtures.
- Added `tests/ut/backends/pure_/lang/expressions.d`.
- Wired the new backend expressions module into `tests/main.d`.
- Added the positive `intAddition` test and two negative diagnostic probes:
  `42 != 43` and `7 != 8`.

Verification completed:

- Raw DMD probes used `dmd -checkaction=context -unittest -main -run ...`.
- `dub test -- ut.backends.pure_.lang.expressions` passed.
- `dub test` passed with 833 tests and 0 failures.

Next migration should continue with the next unmigrated test in
`tests/ut/executors/pure_/lang/expressions.d`: `intSubtraction`.

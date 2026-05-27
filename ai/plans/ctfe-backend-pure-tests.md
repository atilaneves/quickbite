# Ctfe Backend Pure Test Migration Plan

## Summary

Migrate existing `tests/ut/executors/pure_` coverage to Ctfe backend tests in
small source-order slices. The executor tests are source material only: copy the
D fixture shape and expected language behaviour, but do not import, call, or
exercise executor code from backend tests or backend implementation.

Use branch/worktree `ctfe-pure-backend-tests` at
`worktrees/ctfe-pure-backend-tests`. Use one shared slice worktree for the main
agent and subagents. Land one coherent migrated source-order slice per PR.

## Key Changes

- Treat existing backend `eval.d` coverage as complete.
- Add unittest-style Ctfe backend tests under `tests/ut/backends/pure_`, using
  valid D source that contains `unittest` blocks.
- When asking for test approval, show the exact proposed test bodies in a
  language-tagged code block. A raw unified diff alone is not a readable
  approval artifact.
- Do not convert unittest fixtures into REPL-only snippets that are not valid D.
- Each migrated positive test needs a matching negative assertion probe. Passing
  unittests do not print or throw, so the negative probe proves the unittest ran
  and exposes the observed value through the failure diagnostic.
- All negative assertion probes must check `-checkaction=context`-style failure
  messages. Always verify the actual CTFE engine output for the failing
  assertion before encoding the expected diagnostic. "Actual CTFE engine
  output" means a real DMD command such as
  `dmd -o- -checkaction=context fixture.d`, not only the current
  dmd-as-a-library wrapper output.
- If DMD CLI output and dmd-as-a-library output disagree, first check whether
  Quickbite's DMD global state matches the CLI switches used by the oracle. For
  assertion diagnostics, `global.params.checkAction` must be
  `CHECKACTION.context`.
- Failed unittest diagnostics must come from executing CTFE, thrown exceptions,
  or DMD diagnostics. Do not walk the unittest body after failure to
  reconstruct the diagnostic that should have happened.
- Convert executor fixtures by preserving the D language behavior, not the
  executor plumbing:
  - Keep `unittest` blocks and assertions in the backend source.
  - Copy only the fixture shape needed to express the language behaviour.
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

## Architecture Constraints

- Backend source and backend tests must not import `quickbite.executor`,
  `quickbite.executors`, executor test helpers, or executor modules.
- Backend implementation must not route through old executor APIs or executor
  `Value` types.
- Backend tests copy only the D fixture shape from executor tests. They must not
  exercise executor code as part of proving backend behaviour.
- Do not add fallback paths. Unsupported shapes should stay unsupported until a
  test forces the exact next shape.
- Keep the architecture guard in `tests/ut/backends/architecture.d` focused on
  backend source and backend tests.

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
- The conversion does not import, call, or exercise executor code.
- The implementation contains no fallback path or broad support not forced by
  the focused migrated test.

After implementation, spawn or reuse a reviewer subagent to review the
production change before committing.

## Subagent Workflow Per Migrated Slice

1. The coordinator picks the next unmigrated executor pure test or coherent
   source-order group in source order and assigns exactly one migration
   subagent when useful.
2. The migration subagent mechanically copies the executor test shape into the
   backend test module:
   - Preserve the D fixture body as literally as possible.
   - Change only the harness from executor API calls to backend API calls.
   - Add the matching negative assertion probe for the same observable value.
   - Do not edit production code.
   - Stop with the proposed test diff for user approval before the coordinator
     applies or asks for edits to the test.
3. After test approval, the coordinator applies the test and assigns a separate
   verifier subagent.
4. The verifier subagent runs the focused backend test and verifies the
   negative probe against real CTFE output:
   - First run a real DMD CLI probe with `-checkaction=context` for the fixture
     shape whose diagnostic will be encoded.
   - If in-process CTFE disagrees with the CLI probe, inspect the DMD global
     parameters before changing tests or adding backend diagnostic code.
   - If the focused test is green, report that no production code is currently
     justified.
   - If the focused test is red, report the exact failing test, observed
     diagnostic, expected diagnostic, and why the failure is the intended
     language gap.
   - The verifier does not edit tests or production code.
5. For a verifier-confirmed red Ctfe gap, the coordinator assigns exactly one
   implementer subagent with bounded ownership of the production files needed
   for that single red test.
6. The implementer subagent writes the smallest production change that makes
   only that focused test pass:
   - Do not add general diagnostic filtering, assertion walking, fallback
     behaviour, executor integration, or support for a future fixture shape.
   - Reuse existing backend/eval machinery instead of duplicating CTFE
     evaluation paths.
   - Stop once the focused test is green.
7. The coordinator reviews the implementer diff. If the implementation is
   broader than the focused test requires, delete or delegate deletion until the
   focused test is the reason every remaining line exists.
8. Run the focused backend test including `ut.backends.architecture`. Run
   `dub test` before committing unless the session owner explicitly narrows
   verification to focused tests.
9. Spawn or reuse a reviewer subagent only after the focused implementation is
   minimal and green.
10. Present implementation-review findings one by one; apply only approved
    fixes.
11. Commit the completed migrated test and implementation as one commit.
12. Stop after that migrated slice and create a PR. Do not start the next
    slice in the same PR.

## PR Boundary

The orchestrator must stop after one migrated source-order slice and create a
PR. A slice may contain a coherent group such as the integer binary operations
in `expressions.d`; do not mix unrelated language areas in one PR.

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
- Include `ut.backends.architecture` in focused backend verification.
- Verify every negative assertion diagnostic against the actual CTFE engine
  output before encoding the expected message. Use a real DMD CLI probe with
  `-checkaction=context`; do not treat current wrapper output as canonical when
  it disagrees with the CLI.
- Run `dub test` after every implementation/review cycle and before each
  commit, unless the session owner explicitly narrows verification to focused
  tests.
- Before each commit, confirm the backend test is valid-D unittest source,
  any needed conversion review happened, negative diagnostics use verified
  `-checkaction=context`-style messages, no temporary probes are left, and
  the agreed verification passes.

## Assumptions

- Scope includes all current `tests/ut/executors/pure_` tests, including
  minicereal and cerealed project-inspired tests.
- Existing backend `eval.d` migration is accepted as complete.
- One commit per migrated slice.
- Shared slice worktree for main agent, implementer, and reviewer subagents.

## Handoff Status

Branch `ctfe-pure-backend-tests` contains the first migrated backend test:
`expressions.d` / `intAddition`. PR 44 has been updated with the review-comment
fixes for this slice.

Implemented in this slice:

- Added backend-level `runTests(in string moduleSource)`.
- Implemented `Ctfe.runTests` for valid-D unittest fixtures.
- Added `tests/ut/backends/pure_/lang/expressions.d`.
- Wired the new backend expressions module into `tests/main.d`.
- Added the positive `intAddition` test and two negative diagnostic probes:
  `42 != 43` and `7 != 8`.
- Added `parseModuleWithCheckActionContext` for Ctfe backend unittest parsing,
  keeping `CHECKACTION.context` scoped to that path instead of changing the
  default compiler API state.
- Removed post-failure unittest body walking for assertion diagnostics. Ctfe
  backend unittest failures now surface DMD diagnostics from CTFE execution.

Verification completed:

- Raw DMD probes used `dmd -checkaction=context -unittest -main -run ...`.
- Focused verification passed:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.expressions`.
- Narrow regression check passed after scoping `CHECKACTION.context`:
  `dub test -- ut.executors.api.runModulesTests.runsBothModules`.
- A full `dub test` run was started by mistake and stopped; do not treat it as
  verification for this PR.
- PR 44 review threads were marked resolved after the branch update.

Review feedback learned for this slice:

- The current `intAddition` backend tests only require running a unittest
  through CTFE, detecting a failed final equality assertion, and reporting the
  observed integer values for the two negative probes.
- `ctfeValue` already handles integer CTFE expressions for `eval`; assertion
  operand reporting should reuse that path rather than adding a second
  integer-only CTFE evaluator.
- Do not write implementation code unless a test forces it to exist. When a
  test does force code, write the bare minimum that makes the test pass.
- Do not keep general CTFE diagnostic filtering, broad assertion walking,
  fallback paths, or future unittest failure support without a test that
  forces it.
- If a CTFE assertion diagnostic lacks `-checkaction=context` values, check
  dmd-as-a-library initialization before changing tests. The CLI oracle already
  reports values for fixtures such as `assert(1 == 2)` when run as
  `dmd -o- -checkaction=context fixture.d`.
- The fix for this slice was using a scoped parse path that temporarily sets
  `global.params.checkAction = CHECKACTION.context` while parsing Ctfe backend
  unittest fixtures, then surfacing DMD diagnostics, not re-walking the unittest
  body to synthesize `42 != 43`.
- Generated backend test names should use stable numeric suffixes such as
  `intAdditionFailureMessage.0.Ctfe` and `intAdditionFailureMessage.1.Ctfe`.

Next migration should continue with the next unmigrated source-order slice in
`tests/ut/executors/pure_/lang/expressions.d`: the remaining integer binary
operation tests after `intAddition`.

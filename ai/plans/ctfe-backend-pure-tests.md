# Ctfe Backend Pure Test Migration Plan

## Summary

Migrate existing `tests/ut/executors/pure_` coverage to Ctfe backend tests one
source module per PR. The executor tests are source material only: copy the D
fixture shape and expected language behaviour, but do not import, call, or
exercise executor code from backend tests or backend implementation.

Start each migration PR from a fresh worktree under `worktrees/`, named after
the branch for that PR. Do not reuse a stale completed migration branch unless
the user explicitly asks for it.

Pick one unmigrated module per PR, such as `arrays.d`, and migrate that whole
module at once. Keep the backend tests in the same order as the executor tests
they came from. If the module is green, audit-poke all migrated positive tests
in one focused run, restore the poke, run full verification, and create the PR
with the migrated tests and handoff plan update. If the module is red, first
fix migration mistakes; talk before implementing a true backend gap.

## Key Changes

- Treat existing backend `eval.d` coverage as complete.
- Add unittest-style Ctfe backend tests under `tests/ut/backends/pure_`, using
  valid D source that contains `unittest` blocks.
- This migration plan intentionally does not use a per-test approval gate.
  These tests are migrations of previously approved executor tests, not new
  language-surface coverage. Apply migrated backend tests directly, then verify
  them with the probe/focused-test/audit-poke loop below.
- Migrate the selected module in one batch rather than committing one test at a
  time. Preserve the order of the original executor tests inside the backend
  module.
- Do not convert unittest fixtures into REPL-only snippets that are not valid D.
- Each migrated positive test needs at least two matching negative assertion
  probes when practical. Passing unittests do not print or throw, so the
  negative probes prove the unittest ran, expose the observed value through the
  failure diagnostic, and make naive canned implementations harder to satisfy.
- The negative probes should fail in different ways. For example, if the
  positive test proves `answer == 42`, add one probe expecting `43` and another
  fixture shape whose observed value is different, such as `7`, expecting `8`.
  If a second negative probe would be meaningless or would broaden the fixture
  beyond the migrated language behaviour, document why one probe is enough in
  the handoff.
- All negative assertion probes must check `-checkaction=context`-style failure
  messages. Always verify the actual CTFE engine output for the failing
  assertion before encoding the expected diagnostic. "Actual CTFE engine
  output" means a real DMD command such as
  `dmd -o- -checkaction=context fixture.d`, not only the current
  dmd-as-a-library wrapper output.
- DMD CLI diagnostic probes must stay inside the active migration worktree.
  Delegate these probes to a subagent whenever subagents are available for the
  migration. The main agent should integrate the reported diagnostics instead
  of running ad hoc probes itself. The probing subagent should prefer
  temporarily editing the backend test fixture under migration, then restore it
  before reporting. If a separate fixture file is truly needed, create it only
  inside the active worktree, delete it before reporting, and mention why the
  backend test file itself was not enough.
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
  - For `assert(x == expected)`, keep the positive assertion and add negative
    probes that make the same observable value fail in different ways.
  - Mutation/control-flow tests assert the final observable value.
  - Struct tests assert a field or derived scalar/array value.
  - Exception tests assert the catch result or message string when that is the D
    feature under test.
  - Diagnostic/unittest-failure tests keep only the underlying D feature
    behavior unless the diagnostic itself is the behavior under migration.
- If a migrated positive test passes immediately, keep it as already-supported
  behavior only after its negative probes have failed with verified CTFE
  diagnostics or after the final broad audit poke proves the positive unittest
  executed.

## Architecture Constraints

- Backend source and backend tests must not import `quickbite.executor`,
  `quickbite.executors`, executor test helpers, or executor modules.
- Backend implementation must not route through old executor APIs or executor
  `Value` types.
- Backend tests copy only the D fixture shape from executor tests. They must not
  exercise executor code as part of proving backend behaviour.
- Do not add fallback paths. Unsupported shapes should stay unsupported until a
  test forces the exact next shape.
- If making a migrated backend test pass requires inspecting a failed
  diagnostic and then reconstructing a better diagnostic, stop. Do not
  implement it. Report that the test is blocked until the backend can produce
  the diagnostic through normal execution.
- Rejected patterns for Ctfe backend migration:
  - Parsing DMD diagnostic text.
  - Detecting placeholder substrings such as `<double not supported>`.
  - Walking unittest bodies after CTFE failure.
  - Reconstructing operand values from declarations after failure.
  - Adding fallback paths for one backend to mimic another backend.
  - Treating a handoff note as permission to override this plan.
- Keep the architecture guard in `tests/ut/backends/architecture.d` focused on
  backend source and backend tests.

## Review Gates

Use judgment on whether a conversion reviewer is useful. Source-preserving
migrations that keep the same valid-D fixture and add only the required
negative diagnostic probes do not need a separate conversion reviewer.

When used, the conversion reviewer must check that:

- The converted test still covers the same D language feature.
- No important behavior was lost while moving to Ctfe backend coverage.
- The source remains valid D.
- The positive unittest has a clear observable assertion.
- The negative probes verify the same observable value with a
  `-checkaction=context`-style diagnostic checked against real CTFE output.
- Runtime-shaped fixtures still avoid accidental constant folding.
- The conversion does not introduce unrelated backend API expansion.
- The conversion does not import, call, or exercise executor code.
- The implementation contains no fallback path or broad support not forced by
  the focused migrated test.

Do not require an additional conversion reviewer subagent for straightforward
source-preserving module migration where the conversion keeps the same valid-D
fixture shape and only adds the required negative probes.

After implementation, spawn or reuse a reviewer subagent to review production
changes before committing.

If a task handoff contradicts this plan, `AGENTS.md`, or `ai/mistakes.md`,
stop and ask. Do not treat the handoff as an exception unless the user
explicitly approves the exact exception after seeing the conflicting rule.

## Migration Workflow Per Module

1. Create a fresh branch and worktree for the PR.
2. Pick the next unmigrated executor pure module from the migration order.
3. Add or update the matching backend module and wire it into `tests/main.d` if
   needed.
4. Migrate the selected executor module all at once:
   - Copy the valid-D fixture shapes into the matching backend module.
   - Change only the harness from executor API calls to backend API calls.
   - Add at least two matching negative assertion probes for each migrated
     positive test when practical.
   - Keep backend tests valid D with `unittest` blocks.
   - Keep migrated tests in the same order as the original executor tests and
     reject unrelated edits.
5. Verify negative diagnostics against real DMD CLI output with
   `dmd -o- -checkaction=context` before encoding or adjusting the expected
   message. Run this from the active worktree and keep probe edits in the
   backend test file being migrated whenever possible; do not create probe
   files outside the worktree unless the backend test file itself is
   impractical.
6. Run the focused backend test including `ut.backends.architecture`.
7. If the module is red:
   - Fix migration mistakes directly and rerun focused verification.
   - If the red is caused by DMD CTFE floating-point assertion formatter
     placeholders such as `<float not supported>`, treat it as fake red: mark
     the affected test with `@ShouldFail(...)`, document the formatter reason,
     verify, and continue.
   - If it is a true backend gap, stop normal migration and talk before
     implementing the smallest backend change for that behaviour.
8. If the module is green, run one broad audit poke before committing:
   temporarily make all migrated positive tests expect failure, run the focused
   test, confirm unit-threaded reports every poked positive test as failing,
   then restore the source to pristine condition. Do not commit the poke.
9. For a true red Ctfe gap, keep implementation bounded to the production files
   needed for that single red test:
   - Do not add general diagnostic filtering, assertion walking, fallback
     behaviour, executor integration, or support for a future fixture shape.
   - For a single migrated assertion-diagnostic test, production changes should
     be small and local. If the proposed implementation needs broad AST
     walking, statement traversal, diagnostic parsing, or more than a few
     focused helpers, stop and ask for review before editing.
   - Reuse existing backend/eval machinery instead of duplicating CTFE
     evaluation paths.
   - Stop once the focused test is green.
10. Review the implementation diff. If the implementation is broader than the
   focused test requires, delete or delegate deletion until the focused test is
   the reason every remaining line exists. Before committing, compare the
   production diff against the single failing test. If any helper exists only to
   support future shapes, broad reconstruction, or diagnostic cleanup, remove
   it before verification.
11. Spawn or reuse a reviewer subagent only after the focused implementation is
   minimal and green.
12. Present implementation-review findings one by one; apply only approved
   fixes.
13. Run `dub test` before creating the PR unless the session owner explicitly
   narrows verification to focused tests.
14. Commit the migrated module once focused verification, the broad audit poke,
    and full verification pass.
15. Stop after the chosen module is migrated, or after the agreed coherent
    module subset is complete. Create a PR before starting the next module.

## PR Boundary

The orchestrator must stop after one migrated module, or one agreed coherent
module subset, and create a PR. Do not mix unrelated language areas in one PR.

At that point:

- Run `dub test`.
- Ensure all review comments are resolved.
- Update this plan's handoff section with the migrated module boundary, any
  fake reds marked `@ShouldFail`, any true backend gaps fixed, exact
  verification commands run, broad audit-poke result, and the next module a
  following agent should start from.
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

- Run the focused unit-threaded test after migrating the whole backend module.
- Include `ut.backends.architecture` in focused backend verification.
- Verify negative assertion diagnostics against the actual CTFE engine output
  before encoding the expected message. Use a real DMD CLI probe with
  `-checkaction=context` from inside the active worktree; do not treat current
  wrapper output as canonical when it disagrees with the CLI.
- Add at least two negative assertion probes for each migrated positive test
  when practical, with different observed values or failure shapes to catch
  naive implementations.
- After focused verification passes, audit-poke all migrated positive tests in
  one focused run, restore the poke, and rerun focused verification.
- Run `dub test` before committing the module, unless the session owner
  explicitly narrows verification to focused tests.
- Before committing, confirm the backend test is valid-D unittest source, any
  needed conversion review happened, negative diagnostics use verified
  `-checkaction=context`-style messages, no temporary probes are left, and the
  agreed verification passes.

## Assumptions

- Scope includes all current `tests/ut/executors/pure_` tests, including
  minicereal and cerealed project-inspired tests.
- Existing backend `eval.d` migration is accepted as complete.
- Commit each successfully migrated module before continuing to the next
  module.
- Use a fresh migration worktree per PR unless the user explicitly asks to
  reuse an existing worktree.

## Handoff Status

Completed migrations:

- PR 44 migrated `expressions.d` / `intAddition`.
- PR 45 migrated the remaining integer binary-operation tests in the first
  `expressions.d` group: `intSubtraction`, `intMultiplication`, `intDivision`,
  `intModulo`, `intShiftRight`, `intShiftLeft`, `intBitwiseOr`,
  `intBitwiseAnd`, and `intBitwiseXor`.
- PR 46 migrated the remaining `expressions.d` slice through
  `ubyteLocalTruncatesOnStore`, after the earlier expression PRs.
- Current `ctfe-pure-logic` branch migrated all `logic.d` fixtures, including
  the final dmd-codegen-only comparison-operands fixture as
  `logicalAndComparisonOperands`.
- Current `ctfe-pure-control-flow` branch migrated all `control_flow.d`
  fixtures in one module-sized slice.
- Current `ctfe-backend-pure-tests` branch migrated all `arrays.d` fixtures in
  one module-sized slice.

Implemented so far:

- Added backend-level `runTests(in string moduleSource)`.
- Implemented `Ctfe.runTests` for valid-D unittest fixtures.
- Added `tests/ut/backends/pure_/lang/expressions.d`.
- Wired the backend expressions module into `tests/main.d`.
- Added `parseModuleWithCheckActionContext` for Ctfe backend unittest parsing,
  keeping `CHECKACTION.context` scoped to that path instead of changing the
  default compiler API state.
- Removed post-failure unittest body walking for assertion diagnostics. Ctfe
  backend unittest failures now surface DMD diagnostics from CTFE execution.
- Added `tests/ut/backends/pure_/lang/logic.d`.
- Wired the backend logic module into `tests/main.d`.
- Added `tests/ut/backends/pure_/lang/control_flow.d`.
- Wired the backend control-flow module into `tests/main.d`.
- Added `tests/ut/backends/pure_/lang/arrays.d`.
- Wired the backend arrays module into `tests/main.d`.
- Removed the rejected PR 46 Ctfe backend fallback for DMD CTFE floating-point
  assertion diagnostics that contain placeholders such as
  `<double not supported>`. Do not restore or refine that fallback.
- Marked `distinguishesFloatingPointValuesFailureMessage.Ctfe` with
  `@ShouldFail(...)` explaining that DMD CTFE returns
  `<double not supported>` because druntime's assert formatter uses runtime
  `sprintf`.

Verification completed:

- PR 44 focused verification passed:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.expressions`.
- PR 44 narrow regression check passed after scoping `CHECKACTION.context`:
  `dub test -- ut.executors.api.runModulesTests.runsBothModules`.
- PR 45 focused verification passed:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.expressions`.
- PR 45 full verification passed: `dub test`.
- PR 46 focused verification passed:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.expressions`.
- PR 46 negative poke passed: temporarily changing the positive
  `distinguishesFloatingPointValues.Ctfe` assertion to fail made the focused
  command go red with `1.5 != 2.5`; the assertion was restored and the focused
  command passed again.
- PR 46 full verification passed: `dub test`.
- PR 46 benchmark smoke passed: `benchmarks/run.sh`.
- Raw DMD probes used `dmd -checkaction=context -unittest -main -run ...`.
- After removing the rejected PR 46 fallback, focused verification passed with
  the expected-failure marker:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.expressions`
  reported `43 test(s) run, 0 failed, 1/1 failing as expected`.
- After adding the expected-failure marker, full verification passed:
  `dub test` reported `873 test(s) run, 0 failed, 1/1 failing as expected`.
- Current `ctfe-pure-logic` branch focused verification passed:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.logic`.
- Current `ctfe-pure-logic` branch full verification passed:
  `dub test` reported
  `947 test(s) run, 0 failed, 9/9 failing as expected`.
- No true Ctfe backend gaps were found while migrating `logic.d`.
- No new `@ShouldFail` fake reds were needed while migrating `logic.d`.
- Current `ctfe-pure-control-flow` branch focused verification passed:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.control_flow`.
- Current `ctfe-pure-control-flow` branch audit poke passed: temporarily
  changing all 35 positive control-flow backend tests to expect a sentinel
  throw made the focused command go red with 35 unit-threaded failures; the
  file was restored and focused verification passed again.
- Current `ctfe-pure-control-flow` branch full verification passed:
  `dub test` reported
  `1053 test(s) run, 0 failed, 9/9 failing as expected`.
- No true Ctfe backend gaps were found while migrating `control_flow.d`.
- No new `@ShouldFail` fake reds were needed while migrating `control_flow.d`.
- Current `ctfe-backend-pure-tests` branch focused verification passed:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.arrays`.
- Current `ctfe-backend-pure-tests` branch audit poke passed: temporarily
  changing all 20 positive arrays backend tests to expect a sentinel throw made
  the focused command go red with 20 unit-threaded failures; the file was
  restored and focused verification passed again.
- Current `ctfe-backend-pure-tests` branch full verification passed:
  `dub test` reported
  `1116 test(s) run, 0 failed, 9/9 failing as expected`.
- Current `ctfe-backend-pure-tests` branch benchmark smoke passed:
  `benchmarks/run.sh`.
- No true Ctfe backend gaps were found while migrating `arrays.d`.
- No new `@ShouldFail` fake reds were needed while migrating `arrays.d`.

Review feedback learned:

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
- PR 46 review rejected the fallback approach. The review direction is to fix
  floating-point assertion diagnostics at the source, not after failure. Do not
  parse CTFE diagnostic strings, detect `<double not supported>` placeholders,
  walk the unittest body after failure, or synthesize messages from local
  declarations.
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
- DMD's generated `core.internal.dassert._d_assert_fail` path has no suitable
  Quickbite hook for CTFE floating-point formatting in this DMD version.
  Do not spoof or shadow `core.internal.dassert` with import-path tricks, and
  do not add a Quickbite-created hook. If a future DMD version exposes a real
  supported hook, that is different and can be evaluated directly.
- For similar DMD CTFE floating-point formatter limitations that Quickbite
  cannot control, use `@ShouldFail("...")` with a specific reason string
  explaining the upstream limitation. Placeholders such as
  `<float not supported>`, `<double not supported>`, and other floating scalar
  variants are the same formatter limitation, not separate true reds. Do not
  leave a bare `@ShouldFail`.

Next MR should move to the next module in the migration order:
`tests/ut/executors/pure_/lang/structs.d`.

Start by adding the matching Ctfe backend test module and wiring it into
`tests/main.d` if it does not already exist. Then migrate the whole source
module at once, keeping tests in their original order and using the same
positive unittest, negative assertion probes, DMD oracle, broad audit-poke,
`@ShouldFail` formatter-placeholder, focused verification, full `dub test`,
and per-module commit rules.

## Handoff After Arrays Migration

- Branch/worktree: `ctfe-backend-pure-tests` at
  `worktrees/ctfe-backend-pure-tests`.
- Migrated all current `tests/ut/executors/pure_/lang/arrays.d` fixtures to
  `tests/ut/backends/pure_/lang/arrays.d`.
- Added negative assertion probes for observable passing tests where
  practical.
- No production code changes were needed.
- Focused verification passed:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.arrays`.
- Audit poke passed: all 20 positive migrated arrays tests were temporarily
  changed to expect a sentinel throw, and unit-threaded reported all 20
  failures in one focused run. The poke was restored.
- Full verification passed: `dub test` reported
  `1116 test(s) run, 0 failed, 9/9 failing as expected`.
- Benchmark smoke passed: `benchmarks/run.sh`.
- Next agent should start the next MR from
  `tests/ut/executors/pure_/lang/structs.d`.

## Handoff After Control Flow Migration

- Branch/worktree: `ctfe-pure-control-flow` at
  `worktrees/ctfe-pure-control-flow`.
- Migrated all current `tests/ut/executors/pure_/lang/control_flow.d`
  fixtures to `tests/ut/backends/pure_/lang/control_flow.d`.
- Added negative assertion probes for observable passing tests where
  practical.
- No production code changes were needed.
- Focused verification passed:
  `dub test -- ut.backends.architecture ut.backends.pure_.lang.control_flow`.
- Audit poke passed: all 35 positive migrated control-flow tests were
  temporarily changed to expect a sentinel throw, and unit-threaded reported
  all 35 failures in one focused run. The poke was restored.
- Full verification passed: `dub test` reported
  `1053 test(s) run, 0 failed, 9/9 failing as expected`.
- Next agent should start the next MR from
  `tests/ut/executors/pure_/lang/arrays.d`.

## Handoff After PR 46 Cleanup

- Historical branch/worktree: PR 46 used `ctfe-pure-backend-tests` at
  `worktrees/ctfe-pure-backend-tests`. Do not reuse it for the next PR unless
  the user explicitly asks for it.
- Current implementation includes the PR 46 floating-point tests, removal of
  the rejected fallback, and the expected-failure marker for DMD CTFE's
  floating-point assert-message formatting limitation.
- PR: <https://github.com/atilaneves/quickbite/pull/46>.
- The cleanup leaves `Ctfe.runTests` in the simple shape: parse with scoped
  `CHECKACTION.context`, run the synthetic unittest call through
  `ctfeInterpret`, and surface DMD diagnostics directly.
- The reason for `@ShouldFail` is upstream: druntime's generated
  `core.internal.dassert._d_assert_fail` formatter returns placeholders such
  as `<float not supported>` and `<double not supported>` under CTFE for
  floating values because it relies on runtime `sprintf`. Quickbite should not
  repair this after failure, shadow druntime modules, or create an unofficial
  hook.
- Next agent should start the next MR from
  `tests/ut/executors/pure_/lang/control_flow.d`. Continue migrations one
  control-flow test at a time until a true red is found. If no true red is
  found in `control_flow.d`, create the PR for that module. Floating assertion
  formatter placeholders remain expected-fail migration cases, not true reds.

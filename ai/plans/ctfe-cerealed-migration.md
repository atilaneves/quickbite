# CTFE Cerealed Migration

## Goal

Move as much cerealed-derived executor coverage as possible through the new
CTFE backend path while preserving fast, useful unittest feedback.

This is not a plan to force the plain `Ctfe` backend to run all cerealed tests.
The migration uses real cerealed modules as discovery input, extracts focused
backend `pure_` tests from the behaviours they expose, and records unsupported
runtime gaps as expected failures for a later `CtfePlus` backend.

## Current Baseline

- `tests/ut/backends/package.d` has backend helpers for source-string fixtures
  without import paths.
- `tests/ut/backends/pure_` already contains CTFE backend coverage for core
  language behaviours, minicereal, and small cerealed-inspired project cases.
- `tests/ut/executors/deps/cerealed.d` runs only `compile_time.d` for
  `ExecutorName.dmdCtfe`; the other cerealed files are not currently CTFE
  executor coverage.
- `dub test` was green before this plan was written:
  1380 tests, 0 failed, 27 expected failures.

## Implementation Strategy

Add backend fixture helpers with import-path support:

- `runBackendSourceFixtureTests!backend(source, importPaths)`
- `runBackendFileFixtureTests!backend(filePath, importPaths)`

Both helpers should parse through the frontend with the supplied import paths
and then call `backend.runParsedTests` directly. Backend tests must continue not
to import `quickbite.executor`, `quickbite.executors`, or `ut.executors`; keep
`ut.backends.architecture.backendFilesDoNotImportExecutorCode` green.

Start with the existing CTFE cerealed target:

- Add a backend file-fixture test for cerealed `compile_time.d`.
- Use the same dub import paths used by the executor dependency tests.

Then try one cerealed module file at a time, in the existing order from
`tests/ut/executors/deps/cerealed.d`:

1. `bugs.d`
2. `cerealiser_impl.d`
3. `classes.d`
4. `compile_time.d`
5. `decode.d`
6. `encode.d`
7. `encode_decode.d`
8. `enums.d`
9. `example.d`
10. `multidimensional_array.d`
11. `nested.d`
12. `pointers.d`
13. `property.d`
14. `protocol_unit.d`
15. `range.d`
16. `reset.d`
17. `static_array.d`
18. `structs.d`
19. `utils.d`

For each module:

- Try the full module as a backend file fixture.
- If it passes, keep the file fixture.
- Extract only distinct, useful behaviours into
  `tests/ut/backends/pure_/projects/cerealed.d` or the closest related
  `tests/ut/backends/pure_/lang/*` file.
- If the module fails to compile or run, drill down to the smallest useful
  cerealed-inspired behaviour.
- Add extracted behaviours that plain CTFE handles as normal backend `pure_`
  tests.
- Add extracted behaviours that plain CTFE does not handle as `@ShouldFail`
  backend `pure_` tests with a concrete reason.

Do not add a broad opt-in probe harness or a full always-on cerealed matrix.
The workflow is deliberately one module at a time so each committed test has a
clear reason to exist.

## CtfePlus Follow-Up

Do not introduce `CtfePlus` up front.

After every cerealed module has been tried, review the extracted `@ShouldFail`
tests. Introduce `CtfePlus` only when there is a concrete unsupported runtime
gap to implement.

`CtfePlus` should:

- Implement `quickbite.backend.Backend`.
- Delegate to plain CTFE first.
- Add only the minimal missing support proven by an extracted expected-failing
  test.
- Join the normal `ut.backends.backends` matrix only once it passes the
  existing backend suite plus the first promoted expected-failure test.

Plain CTFE remains the correctness oracle for supported `pure_` behaviour.
`CtfePlus` exists to run more cerealed-derived runtime behaviour, not to replace
or weaken CTFE semantics.

## TDD Rules

Follow the repo TDD rules for every slice:

- Stop for approval before adding or modifying a test.
- Show the exact proposed test body before asking for approval.
- Add one failing or expected-failing test at a time.
- Make the smallest implementation change needed for green.
- Do not refactor until tests pass.
- Ask for feedback after the refactoring step.

Run `dub test` after every editing session.

## Progress Log

Keep this section updated as files are tried.

| Cerealed file | Status | Notes |
| --- | --- | --- |
| `bugs.d` | Passed | Added backend file fixture. |
| `cerealiser_impl.d` | Passed | Added backend file fixture. |
| `classes.d` | Blocked | Added extracted class-serialisation `@ShouldFail`. |
| `compile_time.d` | Passed | Added backend file fixture. |
| `decode.d` | Blocked | Added bool decode test and exhaustion `@ShouldFail`. |
| `encode.d` | Blocked | Added int and float encode tests. |
| `encode_decode.d` | Blocked | Added bool round-trip and exhaustion `@ShouldFail`. |
| `enums.d` | Blocked | Added enum round-trip and exhaustion `@ShouldFail`. |

`classes.d` is blocked as a full fixture because it reads cerealed's static
child-class registry `_childCerealisers`, which DMD CTFE cannot read at compile
time.

`decode.d` is blocked as a full fixture because exhausting a bool decoder reads
past the end of cerealed's byte slice; DMD CTFE reports that as an uncaught
bounds error instead of a catchable `RangeError`.

`encode.d` is blocked as a full fixture because cerealed's full test module
still depends on dependency internals outside the extracted backend cases.

`encode_decode.d` is blocked as a full fixture because its generic round-trip
helper also checks for catchable exhaustion after consuming all bytes, which
DMD CTFE reports as an uncaught bounds error.

`enums.d` is blocked as a full fixture because it also checks for catchable
exhaustion after consuming all enum bytes, which DMD CTFE reports as an
uncaught bounds error.

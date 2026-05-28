# CTFE Cerealed Migration

## Goal

Move as much cerealed-derived executor coverage as possible through the new
CTFE backend path while preserving fast, useful unittest feedback.

This is not a plan to force the plain `Ctfe` backend to run all cerealed tests.
The migration uses real cerealed modules as discovery input, extracts focused
backend `pure_` tests from the behaviours they expose, and records true
unsupported runtime gaps for a later `CtfePlus` backend.

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
- Add extracted behaviours where plain CTFE reports a useful diagnostic as
  negative backend `pure_` tests that assert the exact message.
- Use `@ShouldFail` only for real gaps that still need future implementation,
  not for intentional CTFE diagnostics.

Do not add a broad opt-in probe harness or a full always-on cerealed matrix.
The workflow is deliberately one module at a time so each committed test has a
clear reason to exist.

## CtfePlus Follow-Up

The next implementation slice is `CtfePlus`, a backend for runtime features
that DMD CTFE cannot execute, such as mutable static registries and `malloc`.

After every cerealed module has been tried, review the remaining
`@ShouldFail` tests and promote the first concrete unsupported runtime feature
into the initial `CtfePlus` slice.

The first promoted test is
`projects.cerealed.classSerialisationReadsStaticChildRegistry`. Plain `Ctfe`
must keep this test as an expected failure because DMD CTFE cannot read the
static child-class registry at compile time. `CtfePlus` must run the same
behaviour as a normal passing test.

Add a non-virtual capability query to plain CTFE:

```d
public bool canHandle(imported!"dmd.dmodule".Module module_);
```

`canHandle` is a semantic AST support scan, not a test-result predictor. It
must return `false` for modules containing language or runtime features that
DMD CTFE cannot execute, starting with reads of mutable static/dataseg state
such as cerealed's child-class registry. It must still return `true` for
modules whose tests fail through normal assertion failures, bounds diagnostics,
or user-thrown exceptions that DMD CTFE can interpret.

Do not classify DMD CTFE support by matching rendered diagnostic strings. Use
DMD AST nodes, symbols, and semantic helpers as the protocol. For the static
registry slice, the relevant DMD condition is a read of a variable that is in
the data segment and is not CTFE-owned; DMD reports this from `dinterpret.d`
when it cannot find an interpreter value for that variable.

`CtfePlus` should:

- Implement `quickbite.backend.Backend`.
- Compose a private `Ctfe` instance.
- In `runParsedTests(Module)`, delegate the whole module to plain CTFE when
  `_ctfe.canHandle(module_)` returns `true`.
- Run its own fallback only when `_ctfe.canHandle(module_)` returns `false`.
- Add only the minimal missing support proven by an extracted expected-failing
  test.
- Add `runtimeBackends` to `tests/ut/backends/package.d` as the alias sequence
  for backends that can handle runtime-only features beyond plain CTFE.
- Include `CtfePlus` in `runtimeBackends`.
- Include `CtfePlus` in `backends` so it runs the normal backend matrix
  alongside `Ctfe`.

Implement the slice in small TDD steps:

1. Add `runtimeBackends` and include `CtfePlus` in `backends` before defining
   `CtfePlus`; this should fail to compile.
2. Add and export an empty `CtfePlus` class; this should still fail because
   the `Backend` methods are not implemented.
3. Stub the required `Backend` methods; this should compile and fail at
   runtime because `runParsedTests` does nothing.
4. Make `CtfePlus` delegate every method to a private `Ctfe`; the existing
   backend matrix should pass.
5. Move the static child-registry test to `runtimeBackends` and remove its
   `@ShouldFail`; it should fail because `CtfePlus` still delegates to `Ctfe`.
6. Add `public bool canHandle(imported!"dmd.dmodule".Module module_)` to
   `Ctfe`, initially returning `true`, and route `CtfePlus.runParsedTests`
   through it.
7. Implement the static dataseg-read detection directly in the body of
   `Ctfe.canHandle`; do not introduce a `readsUnsupportedStaticDataseg` helper
   or equivalent abstraction before duplication or complexity justifies it.
   The focused `CtfePlus` test should then reach the fallback path instead of
   DMD CTFE's static-variable diagnostic.
8. Implement the smallest fallback that makes the static child-registry test
   pass for `CtfePlus`.

The PR for this slice may be created only when `CtfePlus` passes every backend
test that `Ctfe` passes, plus
`projects.cerealed.classSerialisationReadsStaticChildRegistry`.

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
| `decode.d` | Blocked | Added bool decode test; exhaustion diagnostic asserted. |
| `encode.d` | Blocked | Added int and float encode tests. |
| `encode_decode.d` | Blocked | Added bool round-trip; exhaustion diagnostic asserted. |
| `enums.d` | Blocked | Added enum round-trip; exhaustion diagnostic asserted. |
| `example.d` | Passed | Added dependency-free `Foo` round-trip example. |
| `multidimensional_array.d` | Passed | Added dependency-free nested array byte layout. |
| `nested.d` | Passed | Added dependency-free recursive nested AA byte layout. |
| `pointers.d` | Passed | Added dependency-free pointer-to-int byte layout. |
| `property.d` | Passed | Added dependency-free `ubyte` length array round-trip. |
| `protocol_unit.d` | Passed | Added dependency-free length-field packet round-trip. |
| `range.d` | Blocked | Added dependency-free input range byte layout. |
| `reset.d` | Blocked | Added dependency-free reader reset slice test. |
| `static_array.d` | Blocked | Added dependency-free static array no-length round-trip. |
| `structs.d` | Blocked | Added dependency-free bit-packed struct header round-trip. |
| `utils.d` | Passed | Added backend file fixture. |

Every cerealed file listed in this migration plan has now been tried.

`classes.d` is blocked as a full fixture because it reads cerealed's static
child-class registry `_childCerealisers`, which DMD CTFE cannot read at compile
time.

`decode.d` is blocked as a full fixture because exhausting a bool decoder reads
past the end of cerealed's byte slice. DMD CTFE reports
`array index 6 is out of bounds [0..6]`; this diagnostic is asserted.

`encode.d` is blocked as a full fixture because cerealed's full test module
still depends on dependency internals outside the extracted backend cases.

`encode_decode.d` is blocked as a full fixture because its generic round-trip
helper checks exhaustion after consuming all bytes. DMD CTFE reports
`array index 5 is out of bounds [0..5]`; this diagnostic is asserted.

`enums.d` is blocked as a full fixture because it checks exhaustion after
consuming all enum bytes. DMD CTFE reports
`array index 12 is out of bounds [0..12]`; this diagnostic is asserted.

`range.d` is blocked as a full fixture because it reads the module-scope
`gOutputBytes` buffer at compile time while testing output ranges.

`reset.d` is blocked as a full fixture because its empty decerealiser test
indexes a null byte array at compile time, which DMD CTFE reports as an
uncaught bounds error instead of a catchable `RangeError`.

`static_array.d` is blocked as a full fixture because DMD CTFE reports
`[void, void][0]` as used before initialized while running the module.

`structs.d` is blocked as a full fixture because cerealed reinterprets a
`double*` as a `ulong*` while running the module, and DMD CTFE does not support
that cast.

# Benchmark Driver: Make Results Trustworthy

## Goal

Benchmark output must make two things mechanically clear:

1. which unittest bodies were checked before timing; and
2. which exact unit was timed.

Fast numbers are useful only after that. A row such as:

```text
cerealed                         interpreter      9.720 ms
```

is not credible unless the report also says how many modules and unittests were
prepared, checked, skipped, and timed.

## Current Problem

`./bin/bench.sh -b interpreter --dub cerealed` produces noisy preparation output
and then a single grouped row. The row might be valid, but the driver does not
prove that in the output, and the current single-backend path is too trusting.

Important current behaviour:

- `--dub` discovers source files through `dub describe --config=unittest
  --data=source-files`.
- Discovery keeps in-package source and test modules, excluding only package and
  runner files.
- `prepareFixtureRuns` historically parsed each file by reading its text and
  handing DMD a synthetic `snippet_N.d` filename. File-backed parsing fixed
  that identity bug, but kept the one-file-at-a-time shape.
- With one-file-at-a-time parsing, a package module can be loaded first as an
  import before the benchmark reaches it as a fixture. DMD intentionally skips
  unittest bodies in non-root imported modules and leaves placeholder
  `UnitTestDeclaration`s. Reusing that module later gives the backend an AST
  whose source file has a real unittest body but whose declaration has
  `fbody is null`.
- A module can still be usable for post-parse execution even when the frontend
  timing reparse is impossible. Those rows print `unmeasurable (module
  declaration)`.
- Dub packages are timed as one grouped benchmark unit. For non-`GroupedRunner`
  backends, `runTests(Runner, Module[])` loops over each module.
- With exactly one backend selected, the CLI forces `skipCheck = true` and marks
  every prepared fixture/backend pair as passing without inspecting
  `TestResult[]`.

That last point is the correctness hole. The noise is annoying, but the fake
pass path is worse.

## Check Rule

Bench is not a language-correctness oracle, but it still needs enough checking
to avoid timing nothing, timing a backend that already reported failed
unittests, or comparing timings for backends that did not run the same tests.

Before timing, run the selected backend or backends once on the benchmark unit
and inspect their `TestResult[]`.

For a single selected backend, time the unit only when:

- the backend reports at least one unittest result; and
- every reported unittest passes.

For multiple selected backends, time the unit only when every backend returns
the same `TestResult[]`: same count, same test names, and same pass/fail
outcomes. Failure messages may differ.

`--skip-check` means exactly what it says and bypasses these checks. The
timed row should show the reported pass count so the output proves that the
backend did not benchmark an empty unit.

## Target Shape

Represent everything as benchmark units:

```text
standalone fixture -> one module
dub package        -> all prepared package modules
```

Then use that same unit for:

- the selected backend checks;
- skip decisions;
- unittest counting; and
- timing.

The driver should not claim full language correctness. A single-backend row
only needs to prove that this backend ran at least one unittest before timing,
and that none of those reported tests failed. A multi-backend run should also
prove that all timed backends reported the same test results.

## Work Items

### Current Status

As of 2026-06-17, items 1, 2, and 6 are complete. Benchmark fixture
preparation now parses source files through the frontend's file-backed
`parseModule` path instead of the in-memory `parseSnippet` path. This removed
the old cerealed module-table conflicts during `--dub` preparation, but it
exposed a deeper abstraction mismatch: a dub package is a multi-root
compilation unit, while the bench still prepares its modules one at a time.

`./bin/bench.sh -b ctfe --dub cerealed` now demonstrates the mismatch. The
driver reports that `__unittest_L302_C1` has no available source code, even
though `src/cerealed/scopebuffer.d` plainly has a unittest at that line. The
misleading message comes from reusing an import-loaded non-root module whose
unittest body was skipped by DMD. Running `scopebuffer.d` as a standalone root
gets the more honest downstream CTFE failure: `realloc` cannot be interpreted.

The fix should not be another cerealed-specific workaround. Add a frontend
`parseRootModules` API and make `--dub` prepare the package the way `dub test`
does: establish the discovered package source files as root modules before
imports are parsed, then return the corresponding `Module[]`.

### 1. Stop Implicitly Skipping Checks For Single-Backend Runs

Remove the rule that a single selected backend forces `skipCheck = true`.

Instead:

- `--skip-check` means exactly what it says and is the only implicit-pass path.
- `-b interpreter --dub cerealed` still runs `interpreter` once before timing.
- A single selected backend is timed only if its self-check returns passing
  nonempty `TestResult[]`.
- The timed row reports how many tests were returned and how many passed.

The first test should use fake runners: one runner reports a failing
`TestResult`, and a single selected backend must not be marked passing unless
`--skip-check` is set.

### 2. Compare Results Only For Multi-Backend Runs

Do not compare a single selected backend with an implicit oracle backend.
Cross-backend agreement is useful only when the user explicitly selected more
than one backend to time.

For one backend, keep only a same-backend preflight:

- run the selected backend once on the unit that will be timed;
- collect the returned `TestResult[]`;
- skip timing if the result count is zero;
- skip timing if any result failed; and
- print the pass count in the timed row.

For multiple backends, run every selected backend once on the unit that will be
timed and require all returned `TestResult[]` values to agree on:

- result count;
- test names; and
- pass/fail outcomes.

Failure messages may differ. A mismatch means at least one timed backend did
not run the same benchmark, so skip or reject that row before measuring.

For standalone fixtures, the unit has one module. For dub packages, the unit is
the prepared package module group if the runner supports grouped execution, or
the existing `runTests(Runner, Module[])` fallback otherwise.

### 3. Count Runnable Unittests

Before printing a timed row, compute the number of unittest declarations in the
unit.

Output should make zero-test timing impossible to miss. Prefer failing or
skipping a timed row with a clear reason over reporting a benchmark for zero
unittests.

For grouped dub rows, include at least:

- prepared module count;
- skipped module count;
- reported unittest pass count; and
- check status.

This can be compact. The point is not verbose output; the point is falsifiable
output.

### 4. Separate Preparation From Backend Skips

Stop printing preparation failures as raw `skipping <fixture>: ...` lines before
the sections.

Store them and render them in a preparation section, with wording that does not
look like a backend failure. For example:

```text
== preparation ==
cerealed.cerealiser       not prepared   DMD module-table conflict
```

Keep the full diagnostic available somewhere useful, but make the one-line
report explain the class of failure.

### 5. Make Frontend Measurement Status Explicit

Keep frontend parse+semantic measurement separate from post-parse execution.

Rows marked `unmeasurable (module declaration)` are not backend skips. They mean
the cached module can be used for post-parse execution, but the uncached
frontend reparse collides with DMD process-global module state.

Rename or annotate the section so this distinction is obvious.

### 6. Investigate File-Backed Fixture Parsing - complete

The old parser path read a file and asked DMD to parse it as `snippet_N.d`.
That was convenient for in-memory snippets but poor for dub source files whose
declared module names also appear in real import paths.

Investigate a file-backed parse path for benchmark fixtures:

- DMD should see the real path for modules discovered from dub.
- In-memory snippet benchmarks can keep the synthetic path.
- The source cache key must include the real path or another stable identity so
  same-source files with different module identities cannot collide.

This may reduce the cerealed conflict noise. It is secondary to correctness:
do not depend on it for benchmark checks.

### 7. Keep The Driver Backend-Neutral

The previous bench plan removed most SystemLinker special-casing from the CLI:
backends now come from `benchmarks.backends`, and `runTests(Runner, Module[])`
already abstracts grouped execution.

Preserve that direction. The driver may know that `SystemLinker` is the oracle,
but backend-specific construction policy belongs in the backend factory, not in
the timing loop. The timing loop should not add implicit oracle backends.

### 8. Parse Dub Packages As Root Module Sets

Add `parseRootModules` to `quickbite.frontend.compiler` and route `--dub`
benchmark preparation through it.

The API should model the front-end shape of:

```text
dmd -unittest source/**/*.d -I source
```

not the current loop over independent `parseModule(file)` calls. The exact
internal implementation can use DMD's lower-level `Module` API or a temporary
compiled-import policy, but the public Quickbite contract should be:

```d
ModuleParseResult[] parseRootModules(
    in string[] filePaths,
    in string[] importPaths,
);
```

Required behaviour:

- all `filePaths` are established as root modules before any of their imports
  can parse those same modules as non-root imports;
- DMD sees real file identity for each module, preserving the file-backed fix
  from item 6;
- returned modules follow the input order so benchmark display names stay
  stable;
- if a root file was already loaded as a non-root import with bodyless unittest
  placeholders, fail loudly instead of reusing it as a runnable fixture;
- dependency modules outside the package remain ordinary imports unless they
  are explicitly in `filePaths`;
- standalone fixture parsing keeps using the existing single-file path.

`prepareFixtureRuns` should become two paths:

- standalone fixtures: current `parseModule` path;
- dub packages: a package/root-set path that calls `parseRootModules` once and
  builds one grouped `BenchmarkUnit`.

The frontend timing row for dub packages can stay per module, but its
measurement must not depend on reparsing each root in a way that changes the
prepared AST. If uncached per-module frontend measurement remains impossible
because DMD has process-global module state, keep reporting it as
`unmeasurable (module declaration)` until a true multi-root uncached timing path
exists.

The first approved test should exercise the frontend API directly with two
package-shaped modules where one root imports the other. Running the imported
root's unittest through `Ctfe` must pass, proving that the imported root did not
receive DMD's bodyless non-root placeholder. A second bench-level test can then
show that dub package preparation calls the root-set API and preserves grouped
module order.

Diagnostic cleanup belongs in the same slice or the next one: a bodyless
`UnitTestDeclaration` should not be reported as if the source file lacks a
body. If it is a DMD non-root placeholder, report that the module was parsed as
a non-root import before fixture preparation. Keep "no available source code"
for real external leaves such as `extern(C)` functions.

## Proposed Output Shape

Exact formatting is flexible, but a dub run should communicate this information:

```text
== preparation ==
package      discovered  prepared  skipped
cerealed            35        30        5

== frontend (parse + semantic only) ==
fixture                          status
cerealed.attrs                   unmeasurable (module declaration)
...

== post-parse ==
unit        backend       modules  tests       check   median
cerealed    interpreter        30  151/151     pass    9.720 ms
```

Avoid a wall of conflict diagnostics before the metadata block. A detailed
diagnostic can be printed under the preparation row or behind a future verbose
flag, but the default output should be scannable.

## TDD Notes

Adding or changing tests still needs approval before editing them.

Useful first tests to propose:

1. a single selected backend that reports a failing unittest is not timed unless
   `--skip-check` is set;
2. a backend that reports zero unittest results is not timed unless
   `--skip-check` is set;
3. two selected backends with different `TestResult[]` values are not timed;
4. a passing backend row prints the reported pass count; and
5. preparation skips are rendered as preparation status, not backend status.

Use fake runners for the first driver tests. Do not require a real dub package
or per-test process spawning in unit tests.

For item 8, use file-backed sandbox modules rather than a real dub package:

1. `parseRootModules([importer, imported], [importPath])` keeps the imported
   root's unittest body runnable when `importer` imports it;
2. the same test should run the imported module through `Ctfe` and see one
   passing `TestResult`, not a bodyless-unittest diagnostic;
3. a bench-preparation test can use fake package fixture paths and assert that
   returned benchmark runs preserve input/display order.

## Verification

After implementation, run the required local suite:

```sh
ninja bin/ut
bin/ut --random
```

Then smoke-test benchmark behaviour:

```sh
./bin/bench.sh -w 0 -r 1 -b interpreter --dub cerealed
./bin/bench.sh -w 0 -r 1 -b interpreter -b system-linker --dub cerealed
```

Expected result: a single-backend interpreter row is printed only after the
selected backend has reported at least one passing unittest result. A
multi-backend run is printed only when the selected backends report the same
test results. The output states enough counts to tell whether cerealed's
unittest bodies actually ran.

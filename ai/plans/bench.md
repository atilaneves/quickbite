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
- `prepareFixtureRuns` parses each file by reading its text and handing DMD a
  synthetic `snippet_N.d` filename.
- Some library modules are first loaded by import from their real path and then
  later parsed as synthetic fixtures, or vice versa. DMD reports module-table
  conflicts such as `module cerealed.cerealiser from file snippet_4.d conflicts
  with another module cerealiser from file .../cerealiser.d`.
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
preparation now parses source files through a file-backed frontend path instead
of handing DMD synthetic `snippet_N.d` names, and it reuses modules DMD already
loaded through imports. This removes the cerealed module-table conflicts during
`--dub` preparation. `bench.sh --dub cerealed -b interpreter` still skips timing
because the interpreter self-check reports `Expected array.`; that is backend
behaviour work, not fixture preparation.

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

The current parser path reads a file and asks DMD to parse it as `snippet_N.d`.
That is convenient for in-memory snippets but poor for dub source files whose
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

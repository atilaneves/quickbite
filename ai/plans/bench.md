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

## Oracle Rule

For every backend except `Ctfe`, `SystemLinker` is the behaviour oracle. Bench
must not time another backend on a module or group unless the same unit has been
checked against `SystemLinker`, or the user explicitly passes `--skip-check`.

`Ctfe` is still useful as a backend to measure, but it is not an oracle.

Current exception: `SystemLinker` is not yet reliable for the dub benchmark
path. Until it is, a single selected backend uses a self-check: run that backend
once on the benchmark unit, inspect its `TestResult[]`, and time it only if the
reported tests pass. This is weaker than an oracle comparison, so the output
must show the test pass count instead of implying oracle validation.

## Target Shape

Represent everything as benchmark units:

```text
standalone fixture -> one module
dub package        -> all prepared package modules
```

Then use that same unit for:

- correctness checking;
- skip decisions;
- unittest counting; and
- timing.

The driver should not check per fixture and time per group. That mismatch hides
the answer to "what did this row actually run?".

## Work Items

### 1. Stop Implicitly Skipping Checks For Single-Backend Runs

Remove the rule that a single selected backend forces `skipCheck = true`.

Instead:

- `--skip-check` means exactly what it says and is the only implicit-pass path.
- `-b interpreter --dub cerealed` still runs `interpreter` once before timing.
- A single selected backend is timed only if its self-check returns passing
  `TestResult[]`.
- The timed row reports how many tests were returned and how many passed.
- Once `SystemLinker` works on this path, replace self-check confidence with an
  untimed oracle check for non-`system-linker` backends.

The first test should use fake runners: one runner reports a failing
`TestResult`, and a single selected backend must not be marked passing unless
`--skip-check` is set.

### 2. Check The Same Group That Will Be Timed

Replace fixture-pair checking with benchmark-unit checking.

For standalone fixtures this is unchanged: the unit has one module.

For dub packages, check the grouped `Module[]` unit against the oracle and the
candidate backend. This deliberately matches the timing path and avoids the
known SystemLinker per-fixture completeness gap documented in
`ai/plans/dub-deps.md`.

The check result should be keyed by benchmark unit and backend name, not by
fixture display name alone.

### 3. Count Runnable Unittests

Before printing a timed row, compute the number of unittest declarations in the
unit.

Output should make zero-test timing impossible to miss. Prefer failing or
skipping a timed row with a clear reason over reporting a benchmark for zero
unittests.

For grouped dub rows, include at least:

- prepared module count;
- skipped module count;
- runnable unittest count; and
- checked backend/oracle status.

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

### 6. Investigate File-Backed Fixture Parsing

The current parser path reads a file and asks DMD to parse it as `snippet_N.d`.
That is convenient for in-memory snippets but poor for dub source files whose
declared module names also appear in real import paths.

Investigate a file-backed parse path for benchmark fixtures:

- DMD should see the real path for modules discovered from dub.
- In-memory snippet benchmarks can keep the synthetic path.
- The source cache key must include the real path or another stable identity so
  same-source files with different module identities cannot collide.

This may reduce the cerealed conflict noise. It is secondary to correctness:
do not depend on it for oracle checks.

### 7. Keep The Driver Backend-Neutral

The previous bench plan removed most SystemLinker special-casing from the CLI:
backends now come from `benchmarks.backends`, and `runTests(Runner, Module[])`
already abstracts grouped execution.

Preserve that direction. The driver may know that `SystemLinker` is the oracle,
but backend-specific construction policy belongs in the backend factory, not in
the timing loop.

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
unit        backend       modules  unittests  oracle         median
cerealed    interpreter        30        151  system-linker  9.720 ms
```

Avoid a wall of conflict diagnostics before the metadata block. A detailed
diagnostic can be printed under the preparation row or behind a future verbose
flag, but the default output should be scannable.

## TDD Notes

Adding or changing tests still needs approval before editing them.

Useful first tests to propose:

1. a single selected backend that reports a failing unittest is not timed unless
   `--skip-check` is set;
2. a grouped benchmark unit is checked as the same `Module[]` that timing uses;
3. a grouped unit with zero runnable unittests is skipped or rejected; and
4. preparation skips are rendered as preparation status, not backend status.

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

Expected result: the interpreter row is printed only after the same grouped unit
has been checked, and the output states enough counts to tell whether cerealed's
unittest bodies actually ran.

# Plan: Add Diagnostics To Test Summary

## Context

`runTests` and `runTestSummary` currently serve different callers:

- `runTests` throws on the first failing unittest and preserves the
  diagnostic.
- `runTestSummary` runs every unittest and returns only aggregate counts.

That means `runTestSummary` is useful for reporting pass/fail totals, but
not enough for `runTests` to delegate to it. If callers want both complete
execution and useful failure output, the summary must carry per-test
diagnostics.

## Goal

Make `runTestSummary` rich enough that `runTests` can, at most, be a thin
wrapper around it. `runTests` should keep its current public behavior:
throw when any unittest fails and preserve useful diagnostics. Extend
`TestSummary` with the information needed to do that while keeping the
existing count fields for simple callers.

## Proposed API

```d
public struct TestFailure {
    public size_t index;
    public string name;
    public string message;
}

public struct TestSummary {
    public size_t total;
    public size_t passed;
    public size_t failed;
    public TestFailure[] failures;
}
```

`name` should eventually match D's normal unittest diagnostics: prefer the
UDA name when present, otherwise use a stable source location like druntime
does. The first useful version can fill only `index` and `message`, but the
API should leave room for this.

## TDD Steps

1. Add a test that calls `runTestSummary` on a module with one passing and
   one failing unittest. Assert that:
   - `failed == 1`
   - `failures.length == 1`
   - `failures[0].index` points at the failing unittest
   - `failures[0].message` contains the failure diagnostic
2. Make the IR backend pass by appending a `TestFailure` in its summary
   catch block.
3. Add the same assertion across the backend matrix.
4. Make tree-walking and DMD CTFE append equivalent diagnostics.
5. Teach the shared frontend to expose a display name for each unittest:
   use the unit-threaded-style string UDA when present, otherwise record a
   stable source location.
6. Fill `TestFailure.name` from that shared metadata across all backends.
7. Change `runTests` to delegate to `runTestSummary` only after the summary
   can reproduce the current thrown diagnostics.

## Design Notes

The summary should record user/test failures, not hide backend bugs. If a
backend currently treats an internal unsupported-feature exception as a test
failure, preserve that behavior first and make the diagnostic explicit. A
later cleanup can split expected test failures from backend execution errors
if the public API needs that distinction.

Do not add backend-specific unittest-name discovery. Names and source
locations belong in the shared frontend interface so all backends report the
same test identity.

## Acceptance Criteria

- Existing `summary.total`, `summary.passed`, and `summary.failed` callers
  keep working.
- Every backend records one `TestFailure` entry per failed unittest.
- Failure entries include a test name or source location once the shared
  frontend exposes it.
- Failure messages preserve the useful message currently exposed by
  `runTests` where that backend can provide it.
- `runTests` either delegates to `runTestSummary` or has a documented reason
  why one backend still needs a separate execution path.
- `dub test -- --random` passes.

## 2026-06-03 Handoff Notes

Worktree used during the attempt:

- `/home/atila/coding/d/quickbite/worktrees/test-summary-diagnostics`
- Branch: `test-summary-diagnostics`
- Based on `8d9606f Tighten plans`

That worktree has since been deleted. The notes below summarize what was in
its uncommitted diff.

### WIP Diff From Deleted Worktree

- `source/quickbite/backends/package.d`
  - Added `TestFailure`.
  - Added `TestFailure[] failures` to `TestSummary`.
- `source/quickbite/backends/ctfe/dmd_ctfe.d`
  - Derived `summary.failures` from the existing `TestRunResult.cases`.
  - Contained an attempted CTFE diagnostic cleanup in
    `ctfeFailureMessage`: clear `diagnostics`, clear `global.errors`, and
    copy the diagnostic message with `.idup`. This did not fix the crash
    described below and should be reviewed before keeping.
- `tests/ut/backends/api/runner.d`
  - Extended
    `runTestSummary.countsAttributedPassingAndFailingUnittests.Ctfe` to
    assert one failure, index `1`, name `__unittest_L7_C13`, and a message
    containing `1 == 2`.

Old `quickbite.executor` API work was intentionally abandoned after feedback
that executor tests are going away. Any earlier edits there were reverted.

### What Was Attempted

1. Added the planned backend API directly:

   ```d
   public struct TestFailure {
       public size_t index;
       public string name;
       public string message;
   }

   public struct TestSummary {
       public size_t total;
       public size_t passed;
       public size_t failed;
       public TestFailure[] failures;
   }
   ```

2. Populated CTFE failures by appending a `TestFailure` in the failing branch
   of `runTestResults`.

3. Moved failure derivation out of the traversal callback and derived failures
   from the already-existing `TestRunResult.cases` after traversal.

4. Tried to avoid changing `TestSummary`'s dynamic-array layout by using:

   - a pointer-plus-length representation with a `failures` property;
   - a thread-local backing store plus a `failures` property.

   These were abandoned because they made the API less honest and did not
   resolve the observed crash.

5. Tried clearing DMD CTFE diagnostic state after capturing a failure:

   - copied `diagnosticMessage` with `.idup`;
   - cleared `diagnostics.length`;
   - reset `global.errors`.

   This did not resolve the crash.

### Failure Observed

Focused CTFE backend tests that execute a failing unittest segfault with exit
code `-11` / `139`, usually with no unit-threaded assertion output. Examples:

```sh
dub test --force -- \
  ut.backends.api.runner.runTestSummary.countsAttributedPassingAndFailingUnittests.Ctfe

dub test --force -- \
  ut.backends.api.runner.runTestResults.reportsDmdUnittestSymbolNames.Ctfe
```

The same crash happened in an untouched detached baseline worktree at
`8d9606f`:

```sh
git worktree add --detach /tmp/quickbite-baseline-test 8d9606f
cd /tmp/quickbite-baseline-test
dub test --force -- \
  ut.backends.api.runner.runTestSummary.countsAttributedPassingAndFailingUnittests.Ctfe
```

That means the segfault was not specific to adding `TestSummary.failures`.
The implementation work was blocked by an existing CTFE/focused-test crash.

Debugger notes:

- `gdb -batch -ex run -ex bt --args ...` could not run in the sandbox because
  `ptrace` is not permitted.
- `valgrind` was not installed.
- Running `bin/ut --single ...` still segfaulted.

### Important Process Note

Do not run parallel `dub test` commands in this checkout. One attempt did so
accidentally and hit a DUB artifact race. Subsequent test runs were sequential
and used `--force` when validating the crash.

### Recommended Next Step

First fix or quarantine the existing CTFE focused-test crash for failing
unittests. Once that is stable, resume the straightforward implementation:

1. Keep the planned `TestFailure[] failures` field on
   `quickbite.backends.TestSummary`.
2. Populate it from `TestRunResult.cases` in CTFE.
3. Extend the backend matrix only; do not spend effort on the old
   `quickbite.executor` API unless it becomes relevant again.
4. Re-run the focused backend summary test, then `dub test -- --random`.

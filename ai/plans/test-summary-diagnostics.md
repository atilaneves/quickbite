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
- `dub test` passes.

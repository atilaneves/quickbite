# Plan: New Tree Walker From Scratch

## Context

The current tree walker backend was meant to be developed using strict
TDD. Unfortunately, the cerealed unit tests weren't actually being
run, which means the implementation was not really driven by tests as
intended. This plan is to implement a new tree walker from scratch that
is driven by strict TDD.

Another issue is that using cerealed as a test bed for language
features is desireable, but we don't have unit tests for our backends.
We will discover which unit tests for D language features we need by
implementing this new backend.

## Methodology

The first thing to do is to rename the existing tree walker, appending
`Old` to its name: both the class (`TreeWalkingExecutor` →
`TreeWalkingExecutorOld`) and the corresponding enum value
(`ExecutorBackend.treeWalking` → `treeWalkingOld`). Then introduce a
new `TreeWalkingExecutor` class and a new `ExecutorBackend.treeWalking`
value pointing to it. This is a refactoring step that should not change
anything related to testing, the tests just need to pass.

The new executor must be completely isolated from the old one. Do not
introduce shared executor base classes or helper functions between
`TreeWalkingExecutor` and `TreeWalkingExecutorOld`; duplicate entrypoint
plumbing when needed.

Keep the old and new tree walkers in different modules. Do not keep both
implementations in `tree_walking.d` and compensate with prefixes such as
`newTreeWalking...`. The new module should contain the new
`TreeWalkingExecutor` and its directly needed execution state; the old
module should contain `TreeWalkingExecutorOld` and old-only helpers.

Current progress:

1. `TreeWalkingExecutorOld` has been split from the public
   `ExecutorBackend.treeWalking` entrypoint.
2. The new tree walker can run an empty unittest.
3. The new tree walker can report contextual integer equality failures
   for simple local integer assertions, including an assignment before
   the assertion.
4. Old and new tree walkers have been split into separate modules, with
   new-walker execution state folded directly into the new executor shape.
5. Project-inspired cerealed tests now live in `ut.backends.projects.cerealed`.
   They include `ExecutorBackend.treeWalking`, but those entries bail
   out for now. Follow-up changes should remove the bail-outs one behavior
   at a time and implement the missing new tree walker support.
6. The `projects.cerealed.templateLengthPrefixUsesRequestedWidth`
   `treeWalking` entry now runs on `master`. The new walker covers the
   extracted behaviours needed by that fixture: uninitialised dynamic
   array length, lowered range `foreach` as `ForStatement`, signed
   less-than, local dynamic array append, ref dynamic array append
   writeback, right shift, multiplication, and runtime `ubyte` cast
   truncation.
7. The `projects.cerealed.postIncrementCursorReadAdvancesPosition`
   `treeWalking` entry now runs on `master`. The new walker supports
   `size_t` post-increment index reads through `ref` parameters.
8. The struct cursor read slice is merged on `master`. The new walker supports
   the extracted behaviours for struct methods that post-increment scalar
   fields and read array fields through `bytes[position++]`.
9. The `projects.cerealed.dynamicArrayAppenderPreservesRuntimeByte`
   `treeWalking` entry now runs. The focused language test is
   `structConstructorStoresDynamicArrayParameter`, covering a struct
   constructor that passes a dynamic array parameter to another method, stores
   it in a struct field, and then reads the field length and elements.
10. Nested "arrow" control flow has been flattened in `TreeWalkingExecutor`
    argument and array-expression handling. `dub test` passed after that
    refactor.
11. The unsupported array-expression diagnostic from `evalArrayExpression` is
    covered by `runTests.unsupportedArrayExpressionReportsExpressionKind`.
12. The new tree walker now supports dynamic array slices with runtime lower
    and upper bounds. The focused language test is
    `dynamicArraySliceFromRuntimeBounds`, covering `values[start .. stop]`,
    reading the slice length, and indexing the resulting slice. The array
    helpers have also been renamed from `runArrayExpression` to
    `evalArrayExpression` terminology.
13. The current branch adds `Value`-based expression, local, argument, and
    return storage to the new tree walker for scalar and dynamic array values.
    The focused language tests are `dynamicArrayReturnValue`,
    `dynamicArraySliceReturnValue`, and
    `dynamicArrayReturnValueIndexesCallResult`, covering dynamic arrays
    returned from functions, slice expressions returned from functions, and
    direct indexing of an array-returning call result.
14. The branch has been merged with current `master` after the test
    reorganisation. The dynamic array return tests now live in
    `tests/ut/backend_parity.d`. The review follow-up to reuse the public
    `quickbite.executor.Value` has been applied: `Value` now carries `long[]`
    payloads, and `TreeWalkingExecutor` uses that shared type instead of a
    private backend-only union.
15. PR review cleanup removed the private tree-walker `asLong` wrapper so
    scalar extraction now uses `Value.asLong` directly. The array index helper
    is now named `asArrayIndex`, keeping the `long` to `size_t` conversion
    localized and explicit. The non-throwing dynamic-array probe is now named
    `tryGetArray`, distinct from the throwing `Value.asLongArray` accessor.
16. The branch has been merged with current `master` again after the backend
    test module reorganisation. `dub test` now passes with 707 tests and 0
    failures.
17. PR review follow-up added `dynamicArrayStructFieldReturnValue`, covering a
    struct method returning an array field through an assigned call result. The
    new tree walker now treats array-valued `DotVarExp` expressions as
    `Value(long[])`, matching the existing scalar field path. Review cleanup
    also removed unused duplicate REPL parser helpers from
    `source/quickbite/backends/tree_walking.d`. `dub test` now passes with 711
    tests and 0 failures.

Handoff note for the next agent: this branch already contains one PR worth of
work. It adds shared-`Value` dynamic array return support for the new tree
walker. The latest `dub test` passed with 711 tests and 0 failures. Do not
start another slice on this branch; hand it off as-is unless review asks for
more changes.

After this branch is merged, continue with the next
`ut.backends.projects.cerealed` bailout or red project-inspired fixture. Do not
add or enable new tests that depend on external packages such as cerealed. Use
existing dependency-backed tests only as discovery material, then extract a
dependency-free language fixture in `tests/ut/backends/parity.d` or a
project-inspired fixture in `tests/ut/backends/projects`. Spawn subagents and
orchestrate the TDD loop below instead of doing the next implementation slice
inline in the main thread.

Before starting another slice, check whether the current branch already
contains one PR worth of work: a coherent behavior increment, its focused
language tests, and a green `dub test`. If it does, stop and hand off that PR
as-is. Do not choose another bailout or fixture just because the long-term plan
has more work left.

For each existing cerealed-inspired behavior, take the following steps:

1. Spawn a subagent to inspect the existing dependency-backed test or bailout
   without modifying it. The subagent should identify the first missing language
   behavior and, if useful, confirm the failure in a temporary or otherwise
   untracked way.
2. Spawn a test writer subagent with the failure information so that it can
   write a minimal dependency-free unittest in `language.d` or
   `tests/ut/backends/projects`. This new test must be `static foreach`ed for
   all relevant backends, including the new one. At this point only the new
   dependency-free test should be red.
3. Do not add `ExecutorBackend.treeWalking` to tests that import or require
   cerealed or any other external package as the TDD red step. Enable those
   broader tests only when the dependency-free coverage already passes and the
   change is itself the PR's final verification step.
4. Spawn an implementer subagent that writes the *bare minimum* code to
   make the new unit test pass. Canned answers are fine.
5. Spawn a reviewer subagent to check the implementer did their job
   correctly.
6. Spawn a tester subagent to write another unit test, probably
   similar to the one written in step 2, to expose any overfit
   implementation such as `return 42`.
7. Spawn an implementer subagent to make the failing unit test(s)
   green, with, again, the bare minimum.
8. Spawn a refactoring subagent to refactor the implementation just
   written, keeping all tests green. Its job is not to refactor the
   whole codebase, just the new code just written.
9. Spawn a reviewer subagent to review the refactoring agent's job.
10. Repeat steps 8/9 until the reviewer is satisfied.
11. Spawn a subagent to check the related existing dependency-backed test if it
    is useful as verification. If it is red because of another unsupported
    behavior, leave it disabled for the new tree walker and record the next
    dependency-free slice instead of adding dependency-backed coverage.
12. If the branch is now one PR worth of work, stop and hand it off.
    Otherwise move on to the next cerealed-inspired behavior, i.e. go to 1.

Repeat these steps until the new tree walker passes all cerealed
integration tests. At that point, `TreeWalkingExecutorOld` and
`ExecutorBackend.treeWalkingOld` can be deleted.

## Don't

* Do not edit the source files to make it so things work. Do not write
  unit tests with especially curated source that will happen to work.
  If the backend is incapable of executing correct D code, change the
  backend so that it's capable.
* Do not overfit to cerealed or any other library. Do not write
  backend code that caters to any specific user-written D code.

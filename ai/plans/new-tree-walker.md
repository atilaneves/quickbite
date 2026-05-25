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
5. Project-inspired cerealed tests now live in `ut.projects.cerealed`.
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
11. The unsupported array-expression diagnostic from `runArrayExpression` is
    covered by `runTests.unsupportedArrayExpressionReportsExpressionKind`.

Handoff note for the next agent: this branch already contains one PR worth of
work. It enables
`projects.cerealed.dynamicArrayAppenderPreservesRuntimeByte.treeWalking`, adds
the focused `structConstructorStoresDynamicArrayParameter` language coverage,
flattens the reviewed "arrow" control flow in `TreeWalkingExecutor`, and covers
the unsupported array-expression diagnostic with
`runTests.unsupportedArrayExpressionReportsExpressionKind`. `dub test` passed
with 642 tests and 0 failures after these changes. Do not start another
cerealed slice on this branch; hand it off as-is unless review asks for more
changes.

After this branch is merged, continue with the next `ut.projects.cerealed`
bailout or red project-inspired fixture. Spawn subagents and orchestrate the
TDD loop below instead of doing the next implementation slice inline in the
main thread.

Before starting another slice, check whether the current branch already
contains one PR worth of work: a coherent behavior increment, its focused
language tests, and a green `dub test`. If it does, stop and hand off that PR
as-is. Do not choose another bailout or fixture just because the long-term plan
has more work left.

For each cerealed integration test that we run on all backends, we
take the following steps:

1. Spawn a subagent to add the new tree walker backend to the `static
   foreach` list.  This subagent should confirm the new test entry
   fails.
2. Spawn a subagent to investigate *why* the new tree walker fails
   this particular test. This will nearly always be because of missing
   language features since the new tree walker won't support any to
   begin with.
3. Spawn a test writer subagent with the information of why the
   cerealed integration test is failing so that it can write a
   minimal unittest to add to `language.d`. This new test must be
   `static foreach`ed for all backends, including the new one. At this
   point we will have two failing tests - the cerealed integration one
   and this new unit test.
4. Spawn an implementer subagent that writes the *bare minimum* code to
   make the new unit test pass. Canned answers are fine.
5. Spawn a reviewer subagent to check the implementer did their job
   correctly.
6. Spawn a tester subagent to write another unit test, probably
   similar to the one written in step 3, to expose any overfit
   implementation such as `return 42`.
7. Spawn an implementer subagent to make the failing unit test(s)
   green, with, again, the bare minimum.
8. Spawn a refactoring subagent to refactor the implementation just
   written, keeping all tests green. Its job is not to refactor the
   whole codebase, just the new code just written.
9. Spawn a reviewer subagent to review the refactoring agent's job.
10. Repeat steps 8/9 until the reviewer is satisfied.
11. Spawn a subagent to fix the cerealed integration test if it's red.
    If it's now green it has nothing to do.
12. If the branch is now one PR worth of work, stop and hand it off.
    Otherwise move on to the next cerealed step, i.e. go to 1.

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

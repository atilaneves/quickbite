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

The next refactoring step is to split old and new tree walkers into
separate modules and fold any new-walker execution state directly into
the new executor shape.

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
12. Move on to the next cerealed step, i.e. go to 1.

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

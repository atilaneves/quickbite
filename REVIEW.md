# Critical Review: unify-backend-tests

## Findings

1. High: IR passes structs by value as aliases, so callee mutation can
   leak back to the caller.

   `lowerCallArguments` lowers call arguments as ordinary temporary
   indices. The IR executor then copies the temporary's scalar value
   into the callee temporaries. For structs, that scalar is the index
   into the shared `structs` table, so `StructSet` in the callee writes
   through the same backing storage as the caller.

   That means a case such as `void mutate(S s) { s.x = 2; }` can mutate
   the caller's `S`, which violates D value semantics. Current tests
   cover reading by-value struct parameters, but do not cover mutation
   isolation.

   Relevant code:
   - `source/quickbite/frontend/lowering.d`: `lowerCallArguments`
   - `source/quickbite/backends/ir.d`: `argumentValues`,
     `writeArguments`, and `StructSet`
   - `tests/ut/language.d`: `structPassedToFunction`

2. Medium: the public `quickbite.runTests` API was made backend
   mandatory to serve test consolidation.

   `runTests` now requires an explicit `ExecutorBackend`. That is a
   public API break and conflicts with the plan's common interface,
   which describes source text as the public input while backend
   dispatch remains internal.

   If the goal is only to force tests to name a backend, use a test
   helper or overload rather than removing the default public path.

   Relevant code:
   - `source/quickbite/package.d`: `runTests`
   - `ai/plans/overview.md`: "Common Interface"

3. Medium: the local worktree is dirty and no longer matches the open
   PR exactly.

   The open PR is `#1` against `master`, and the remote branch is at
   `0a9727e`. The local worktree additionally deletes `progress.md`,
   renames `tests/ut/backends.d` to `tests/ut/language.d`, changes jump
   offset types, and updates tests.

   That makes review and merge state ambiguous unless those local
   changes are intentionally part of the next revision.

## Verification

I ran `dub test -- -s` in the `unify-backend-tests` worktree. It
passed with 278 tests run and 0 failed.

The PR CI was also green for Ubuntu and macOS at review time.

# Mistakes To Avoid

- Check the existing tree and layout before editing paths or source-discovery
  settings.

- Verify external APIs and config syntax against the real local source before
  inventing names.

- Follow instructions literally unless there is a documented reason to deviate.

- Never weaken or replace a test to make it pass.

- Keep touched code aligned with repo conventions (OTBS, local imports).

- For `in` parameters and stronger attributes, reconcile signatures properly
  instead of weakening qualifiers.

- Local imports inside functions/types only. `imported!"..."` only for
  parameter and return types.

- `private:` at module top and explicit `public`/`private` per declaration are
  both required.

- DMD helpers such as `Expression.toChars()` and `Type.nextOf()` are not
  `@safe`; wrap them in a small `@trusted` helper before calling from `@safe`
  code.

- Omit empty parens everywhere, including inside `q{...}` fixtures: `doStuff;`
  not `doStuff();`.

- Stop and wait for user feedback after writing or modifying a test. Do not
  apply the test diff and ask after — stop before.

- When converting a fixture to an unsupported-diagnostic test, keep the inner
  assertion for the intended supported behavior.

- Don't use `cast(bool)` for STC bitmask checks; compare the masked value
  against `STC.none`.

- Avoid all-literal fixtures unless constant folding is under test; use runtime
  values (mutable locals, function calls) so DMD cannot fold the expression
  before the VM sees it. This applies to tree-walker tests too.

- Prefer `uint[] values;` over `auto values = cast(uint[]) [];`.

- Don't use variadic functions as call-argument fixtures; they introduce
  DMD/runtime varargs constructs that can fail before the VM reaches the
  intended behavior.

- In a named git worktree, prefix patched paths with the worktree directory
  when the session cwd is the parent checkout.

- Don't run parallel `dub test` in the same checkout; it races on shared build
  artifacts.

- Strict TDD: make the smallest green step (fake if needed), then ask for the
  next test before expanding the implementation.

- Prefer `const`; use `auto` with a reason if `const` fails; use an explicit
  LHS type only if `auto` fails (explain why).

- When adding an `else` branch under `if (auto x = ...)`, brace both branches
  if both need `x`; otherwise `x` is out of scope in the second branch.

- Don't add helper functions to fixtures just to avoid constant folding unless
  the purpose is clear; add a comment if you do; otherwise use a direct runtime
  expression.

- When spawning subagents for backend work, delegate bounded implementation to
  worker agents with disjoint file ownership after test approval — don't
  implement everything in the main thread.

- Give subagents that edit code separate git worktrees unless the user
  explicitly approves sharing a checkout.

- Unit-threaded focused-test arguments use the full name from `./ut -l` (e.g.
  `ut.ir.ir.minicerealFile`), not just the `@("...")` label.

- Don't add broad acceptance tests in TDD unless the current implementation is
  expected to fail them; an immediately-passing test drives no production code.

- Pass review text containing Markdown backticks via a body file or
  single-quoted input, not double quotes.

- Don't run the local test suite during PR review just to confirm CI; use the
  diff and CI signal.

- In DMD 2.112.1 array equality may stay an `EqualExp` without
  `EqualExp.lowering`; don't assume all array equality reaches
  `object.__equals`.

- Apply `@safe` and other attributes to new helpers immediately, not after
  review.

- Don't put expensive work (process spawning) in per-unittest test helpers;
  cache or move it out of the hot path.

- Don't add `@trusted` without a specific justification.

- When told not to use `@trusted`, don't add wrappers around unsafe DMD APIs.
  Leave the caller unannotated or restructure the code instead.

- When a PR replaces a process-spawning CLI call with a library call, don't
  satisfy review comments by hiding the same CLI call behind a library-shaped
  wrapper.

- TDD: for a first red test asking for a count, return the smallest pre-canned
  value; add another approved test to force real implementation before
  refactoring.

- Prefer `.should == expected` over `.shouldEqual(expected)` in new
  unit-threaded tests.

- Don't use unit-threaded assertions or imports inside `q{}` fixture strings;
  keep host-test dependencies out of code under test.

- In `tests/ut/compiler_api.d`, use `shouldThrowWithMessage`, not naked
  `shouldThrow`, so tests verify the relevant diagnostic text.

- Do not mark helpers that mutate `__gshared` state as `@safe`; D rejects
  direct `__gshared` access from `@safe` functions.

- Don't use `throw new Exception` as a failing-test stand-in unless exception
  handling is under test; use `assert`.

- DMD declaration helpers are type-specific. Don't call a `VarDeclaration`
  helper such as `declarationName` with a `FuncDeclaration`; use the existing
  function helper instead.

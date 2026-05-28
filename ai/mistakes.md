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

- When asking for approval to add or modify a test, show the exact proposed
  test or diff before asking.

- For test approval, prefer showing the proposed test code in a
  language-tagged code block over a raw unified diff. Use a diff only when the
  surrounding edit context matters, and still include the test body in a
  syntax-highlighted block if readability would suffer.

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

- Pass multiline PR bodies through a file or another mechanism that preserves
  actual newlines; shell double-quoted `\n` becomes literal backslash-n text.

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

- For established interactive-tool behavior, check the closest precedent
  before designing. For a Python-like REPL, use Python as the default baseline
  and diverge only after explaining the concrete reason.

- Do not make the REPL loop parse or classify D code with string heuristics
  such as suffix checks, delimiter counting, keyword checks, or regexes. Ask
  the frontend/eval API for structured cell status instead.

- Do not use failed REPL evaluation as control flow to distinguish
  expressions from statements/declarations or incomplete input. Exceptions are
  diagnostics/failures, not a parser API.

- Follow the Github section of AGENTS.md: after `gh pr create`, open the
  resulting PR URL in the browser.

- In D, member access through a pointer auto-dereferences (`ptr.field` works),
  but indexing does NOT (`ptr[i]` is pointer arithmetic). To index into a
  struct wrapped in a pointer (e.g. `Array!T*`), always use `(*ptr)[i]`.

- Don't implement TDD cycles inline in the main thread when the plan prescribes
  subagents; see the existing subagent rule above.

- Don't change vendored code for convenience. If a wrapper or helper is needed,
  add Quickbite-owned code instead, and re-vendor to verify vendor files stay
  clean.

- Backend diagnostics should report mechanically-derived facts. Don't classify
  external symbols with hardcoded "known symbol" lists, and don't probe the
  process loader from diagnostics just to guess symbol availability.

- Don't propose adding or enabling dependency-backed tests for new tree walker
  TDD slices; extract dependency-free language or project-inspired tests
  instead.

- Don't add backend-specific workarounds to make tests pass. A backend either
  implements the language behaviour properly enough for the test, or it should
  be left out of that test.

- Do not accept a prior-agent "narrow exception" when it contradicts a local
  plan. Re-read the plan, identify the conflict, and ask before implementing.

- Don't write language-surface tests that encode behaviour different from DMD
  CTFE or compiled D code. For `pure_` tests, CTFE is canonical unless the
  completed dmd codegen backend proves compiled code behaves differently.

- Treat CTFE floating assertion formatter placeholders such as
  `<float not supported>` the same as `<double not supported>`: mark the
  affected migration test `@ShouldFail` with a concrete upstream formatter
  reason instead of calling it a true red.

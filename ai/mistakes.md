# Mistakes To Avoid

- Check the current tree and existing layout before editing paths or
  source discovery settings.

- Verify external APIs and config syntax against the real local source
  before inventing names or shapes.

- Follow explicit user and repo instructions literally unless there is a
  documented reason to deviate.

- Never weaken or replace a test just to make it pass.

- Keep touched code aligned with repo conventions, especially OTBS/OTBC
  and local imports.

- When a user asks for `in` parameters and stronger attributes, do not
  work around the resulting type mismatch by weakening the qualifier
  requirement. Reconcile the signatures properly and add the strongest
  valid attributes instead.

- Do not introduce module-level imports in this repository when a local
  import inside the relevant function or type block would do. Do not
  use `imported!"..."` outside parameter and return types.

- AGENTS.md asks for both `private:` at the top of each module and
  explicit `public` and `private` annotations anyway. Do not treat
  inherited module-private visibility as explicit enough.

- DMD AST formatting helpers such as `Expression.toChars()` are not
  `@safe`; wrap them in a small `@trusted` helper before calling them
  from `@safe` lowering code.

- Do not use empty parentheses for function calls. Omit them: `doStuff;`
  not `doStuff();`. This applies to call sites everywhere, including
  inside `q{...}` test fixtures.

- DMD type helpers such as `Type.nextOf()` are not `@safe`; wrap them
  in a small `@trusted` helper before calling them from `@safe` lowering
  code.

- No-empty-parens style applies inside `q{}` fixture source strings too;
  check no-argument calls there before asking for test feedback.

- When asking for feedback on tests, stop and wait for the user to
  respond before continuing the TDD loop or committing the test.

- Always ask for feedback after adding or modifying tests. Stop and wait
  before changing production code.

- When converting a fixture into an unsupported-diagnostic test, keep the
  inner assertion that describes the intended supported behavior.

- Do not use `cast(bool)` for D storage-class bitmask checks. Compare
  the masked enum value against `STC.none`.

- When testing lowering for a specific operator, do not use all-literal
  expressions unless constant folding is the behavior under test. Use a
  value that survives DMD semantic analysis, such as a function call.

- Do not contort initializers to avoid explicit local array types. Prefer
  `uint[] values;` over noisy forms like `auto values = cast(uint[]) [];`.

- Do not use variadic D functions as simple call-argument fixtures. They
  introduce DMD/runtime varargs constructs and can fail for unrelated
  reasons before the VM reaches the intended behavior.

- When working in a named git worktree, remember that `apply_patch` uses
  the session cwd. Prefix patched paths with the worktree directory when
  the session cwd is the parent checkout.

- Do not run multiple `dub test` commands in parallel in the same
  checkout. Dub may race on shared package build artifacts and fail for
  reasons unrelated to the code.

- In strict TDD, do not implement the full obvious behavior when the
  current red test only forces a fake. Make the smallest green step,
  then ask for feedback on the next test that exposes the fake.

- Do not reinterpret the `const`/`auto`/explicit-type guideline. Prefer
  `const`; if `const` cannot work, use `auto` with a reason. Use an
  explicit LHS type only when `auto` cannot work, and explain why.

- When testing tree-walker runtime semantics, avoid fixtures that DMD can
  constant-fold before the walker sees them. Use runtime locals when the
  test is meant to prove interpreter behavior.

- Stop before changing tests and ask for feedback, even for test-name or
  fixture-style cleanup. Do not apply the test diff first and ask after.

- When adding a sibling branch under `if (auto x = ...)`, use braces if
  both branches need `x`; otherwise the second branch is outside scope.

- Do not add helper functions to test fixtures just to avoid constant
  folding unless the function has a clear purpose. If a helper function
  is needed, add a comment explaining why; otherwise use the smallest
  direct runtime expression, such as a mutable local when mutation or
  non-const evaluation is needed.

- When the user asks for subagents to continue backend work, do not only
  spawn read-only explorers and then implement everything in the main
  thread. After test approval, delegate bounded implementation work to
  worker agents with disjoint file ownership.

- When subagents are expected to edit code, set up separate git
  worktrees first unless the user explicitly asks to share one checkout.
  File ownership alone does not isolate incomplete edits or test runs.

- Unit-threaded focused test arguments must use the full name from
  `./ut -l`, such as `ut.ir.ir.minicerealFile`, not only the display
  label shown by the `@("...")` attribute.

- In strict TDD, do not add broad acceptance tests as the next step
  unless there is a concrete reason to expect the current implementation
  to fail them. If they pass immediately, they did not drive production
  code.

- When passing review text through a shell command, do not put Markdown
  backticks inside double quotes. Use a body file or single-quoted input
  so the shell cannot execute command substitutions.

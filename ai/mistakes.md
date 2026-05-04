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

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

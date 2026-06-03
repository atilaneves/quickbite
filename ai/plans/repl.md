# Plan: REPL

## Goal

When the REPL uses the CTFE backend, it should behave like DMD CTFE does in
real life. Any behavioral deviation from real CTFE is a bug in the REPL or in
how Quickbite drives DMD. For example, CTFE can `pragma(msg)` a
`[1, 2, 3].map!(x => x * 2)` expression successfully, so a CTFE-backed REPL
must not treat that language behavior as unsupported just because the current
`Value` display path cannot represent the result yet.

## Summary

The REPL uses the new backend architecture. Runtime REPL evaluation and REPL
tests must go through the backend REPL API, not executor APIs. The current REPL
is CTFE-only, but the API must stay backend-shaped so later backends can
implement the same cell protocol.

Shared frontend/session code owns parsing, classification, buffering, and
history acceptance. Backends execute complete `ReplCell` values and return
`quickbite.lang.Value`.

## To do

- Add `-I` option to the REPL so that it can be passed import
  paths. This will allow a user to use module names and directory
  structures like regular compiled D code.

## Architecture

- `Backend.evalRepl(ReplCell cell) -> quickbite.lang.Value` is the backend REPL
  entrypoint.
- Expression cells return their evaluated `Value`.
- No-display cells return `Value.void_`.
- CTFE executes non-value cells immediately, not lazily on the next expression.
- `ReplSession` owns DMD frontend state across submitted cells.
- `ReplSession` parses and classifies each single submitted input atom.
- Incomplete cells are reported before backend execution so `Repl` can buffer
  more input.
- `ReplSession` produces `ReplCell` objects for backend execution.
- Shared expression-vs-statement/declaration handling lives in
  `quickbite.frontend.repl`, not in individual backends.
- `Repl.submit(input) -> Value` is the public REPL coordinator API.
- `Repl` owns a `ReplSession` and a backend instance.
- `Repl` buffers incomplete input atoms and only accepts history after a
  complete cell executes.
- `runReplLoop` remains a small test/helper layer over `Repl.submit`.
- Rendering remains outside backend/frontend logic: callers suppress
  `Value.void_`.

## Cling Lessons

Cling and Clang-Repl show that a systems-language REPL should be a
compiler-as-a-service session, not a loose source preprocessor. The useful
lesson for Quickbite is not "use a JIT"; it is to keep one incremental
compiler/frontend session, feed it complete transactions, and let structured
compiler state drive parsing, diagnostics, symbol visibility, and execution.

Apply that lesson this way:

- Treat each submitted cell as a transaction with explicit accept/reject
  semantics. Accepted cells update the session; rejected cells must not poison
  later cells.
- Keep cell classification and incomplete-input detection in the frontend
  session. Do not infer completeness or expression-vs-declaration shape from
  delimiters, keywords, suffixes, or failed evaluation.
- Plan for transaction-level undo once the session model can remove the last
  accepted cell without reconstructing unrelated history.
- Keep REPL commands separate from D source. Commands such as quit, backend
  selection, history, imports, and future library loading should have a
  distinct command path rather than being disguised as D snippets.
- Treat imports and library/dependency loading as session state with explicit
  diagnostics. If future native backends need dynamic-library loading, model it
  as a REPL/session capability instead of hiding it in backend-specific source
  rewriting.
- Preserve compiler compatibility over convenience extensions. If a workaround
  is needed for interpreted mode, keep it explicit and avoid accepting D source
  that normal DMD compilation would reject.
- Keep the binary, library API, and tests on the same evaluation path so the
  interactive prompt is not a special implementation.

## Guardrails

- Use strict TDD and stop for approval before each new or modified test.
- Do not use executors in runtime REPL code or REPL tests.
- Do not add subprocess REPL tests to normal `dub test`.
- Keep binary-level pseudo-TTY REPL checks in standalone scripts such as
  `tests/run_repl.py`, outside the normal unittest build.
- Do not use fake executors for REPL behavior tests.
- Do not reintroduce delimiter counting, suffix checks such as
  `endsWith(";")`, keyword checks, regexes, or other string heuristics to
  classify D source.
- Do not classify DMD diagnostics by searching rendered diagnostic text. Use
  DMD AST nodes, symbols, and semantic helpers as the protocol.
- For `:t` assertion diagnostics, preserve DMD's own context-aware assertion
  lowering by parsing the loaded unittest module with
  `parseModuleWithCheckActionContext`. Do not repair default-parse CTFE
  diagnostics by checking rendered messages for prefixes such as `` `assert ``.
- Do not use failed REPL evaluation as control flow to distinguish expressions
  from statements/declarations or incomplete input. Exceptions are
  diagnostics/failures, not a parser API.
- Do not leave the binary on a different evaluation path than the unit REPL
  loop.
- Do not wrap REPL cells in `unittest` blocks.

## Test Plan

Use strict TDD. Before adding or modifying each test, present the exact
proposed test code and wait for approval.

Test scenarios to cover in `ut.backends.api.repl`:

- Expression cells evaluate until `:q`.
- Declaration cells persist without display.
- Expression side effects persist.
- Statement/declaration cells execute immediately through CTFE.
- Function declaration cells without trailing semicolons persist and can be
  called by later expression cells.
- Multiline function declarations buffer until complete, then persist and can
  be called by later expression cells.
- Import declaration cells persist without display, and imported symbols are
  available to later expression cells.
- `import std;` exposes Phobos symbols to later CTFE expression cells, matching
  DMD CTFE behavior.
- `Repl.submit` returns `Value.void_` for no-display cells.
- CLI backend option parsing accepts default CTFE, `--backend ctfe`, and
  `-b ctfe`.
- CLI backend option parsing rejects unknown backend names with exit status `1`
  behavior represented without spawning a process.

Verification after implementation:

- Run focused tests for the backend REPL module.
- Run `dub test -- --random`.
- Build the REPL configuration with `dub build -c qb`.
- Actually try the REPL binary after building it. At minimum, pipe `1`,
  `int x;`, `++x;`, `x`, a multiline function declaration, a call to that
  function, and `:q` into `bin/qb` and verify expression output appears while
  no-display cells stay quiet.
- Run `tests/run_repl.py` after `dub build -c qb` to verify interactive
  terminal command history through a pseudo-TTY.
- Run `ci.sh` before preparing a PR.

## Assumptions

- Follow-up slices happen in a task-specific worktree and branch unless the
  user explicitly asks to work in the main checkout.
- This plan does not remove executor classes or unrelated executor APIs beyond
  the dead executor REPL entrypoint already removed.
- The REPL remains CTFE-only for now, but the API must avoid CTFE-specific
  duplication so later backends can implement `evalRepl(ReplCell)`.
- The current generated expression-history strategy is preserved unless the new
  frontend session model makes it unnecessary.

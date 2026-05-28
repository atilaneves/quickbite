# Plan: New CTFE REPL

## Summary

Migrate the REPL path to the new backend architecture on the `ctfe-repl`
branch/worktree from `ctfe-benchmark`.

The REPL must stop using executors at runtime and in REPL tests. It should use
the CTFE backend through a simple backend REPL API, while leaving unrelated
executor implementation code in place for later cleanup.

## Progress

Completed in this PR:

- Added `Backend.evalRepl(ReplCell) -> quickbite.lang.Value`.
- Added frontend-owned `ReplSession` and `ReplCell` state.
- Moved `quickbite.repl.runReplLoop` onto `Repl.submit`.
- Implemented CTFE `evalRepl` for expression and no-display cells.
- Replaced normal REPL tests with `ut.backends.repl`.
- Excluded old subprocess-heavy executor REPL tests from normal unittest
  builds without deleting the source file.
- Moved `repl/main.d` to instantiate CTFE directly.
- Added library-level CLI option parser tests for default CTFE,
  `--backend ctfe`, `-b ctfe`, and unknown backends.
- Supported function declarations without requiring semicolons after function
  bodies. For example, `int twice(int i) { return i * 2; }` is accepted as a
  no-display cell and `twice(21)` displays `42: int`.

Remaining follow-up:

- Remove or migrate dead executor REPL APIs after callers no longer need them.
- Add incomplete-input buffering. Multiline declarations such as
  `int thrice(int i) {` currently parse as a complete cell and produce
  diagnostics instead of prompting for the function body before evaluating the
  whole declaration.

## Key Changes

- Add a backend REPL entrypoint:
  - `Backend.evalRepl(ReplCell cell) -> quickbite.lang.Value`.
  - Expression cells return their evaluated `Value`.
  - No-display cells return `Value.void_`.
  - CTFE executes non-value cells immediately, not lazily on the next
    expression.
- Add frontend-owned REPL state in `quickbite.frontend.repl`:
  - `ReplSession` owns DMD frontend state across submitted cells.
  - `ReplSession` parses and classifies each single submitted input atom.
  - `ReplSession` produces `ReplCell` objects for backend execution.
  - Shared expression-vs-statement/declaration handling lives here, not in
    individual backends.
- Add the public REPL coordinator in `quickbite.repl`:
  - Expose `Repl.submit(input) -> Value`.
  - `Repl` owns a `ReplSession` and a backend instance.
  - Keep `runReplLoop` as a small test/helper layer over `Repl.submit`.
  - Rendering remains outside backend/frontend logic: callers suppress
    `Value.void_`.
- Update CTFE backend:
  - Implement `evalRepl(ReplCell)`.
  - Use unique synthetic names where generated CTFE wrappers are still needed.
  - Do not wrap REPL cells in `unittest` blocks.
  - Preserve current REPL behavior unless the backend migration requires a
    mechanical adjustment.
- Update CLI:
  - Instantiate CTFE backend directly by default.
  - Support both `--backend ctfe` and `-b ctfe`.
  - Unknown backend names print a concise diagnostic and exit with status `1`.
  - Do not use executor factories or executor names in the REPL binary.
- Tests:
  - Replace `ut.executors.repl` with `ut.backends.repl`.
  - Remove `ut.executors.repl` from `tests/main.d`.
  - Do not add subprocess REPL tests to normal `dub test`.
  - Unit-test CLI option parsing without spawning `bin/repl`.

## Test Plan

Use strict TDD. Before adding or modifying each test, present the exact proposed
test code and wait for approval.

Test scenarios to cover in `ut.backends.repl`:

- Expression cells evaluate until `:q`.
- Declaration cells persist without display.
- Expression side effects persist.
- Statement/declaration cells execute immediately through CTFE.
- Function declaration cells without trailing semicolons persist and can be
  called by later expression cells.
- `Repl.submit` returns `Value.void_` for no-display cells.
- CLI backend option parsing accepts default CTFE, `--backend ctfe`, and
  `-b ctfe`.
- CLI backend option parsing rejects unknown backend names with exit status `1`
  behavior represented without spawning a process.

Verification after implementation:

- Run focused tests for the new backend REPL module.
- Run `dub test`.
- Build the REPL configuration with `dub build -c repl`.
- Actually try the REPL binary after building it. At minimum, pipe `1`,
  `int x;`, `++x;`, `x`, and `:q` into `bin/repl` and verify expression output
  appears while no-display cells stay quiet.
- Run `bin/bench.sh` before preparing a PR.

## Assumptions

- Work happens in `worktrees/ctfe-repl` on branch `ctfe-repl`, created from
  `ctfe-benchmark`.
- This slice does not remove executor classes or unrelated executor APIs.
- Existing executor REPL methods may remain as dead code if nothing uses them.
- The REPL remains CTFE-only for now, but the API must avoid CTFE-specific
  duplication so later backends can implement `evalRepl(ReplCell)`.
- Input atoms are complete cells for this slice; incomplete-input buffering
  remains out of scope.
- The current generated expression-history strategy is preserved unless the new
  frontend session model makes it unnecessary.

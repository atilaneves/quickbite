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
- Added incomplete-input buffering for multiline function declarations. For
  example, `int thrice(int i) {`, `return i * 3;`, `}` is buffered until the
  declaration is complete, and `thrice(14)` displays `42: int`.
- Hid synthetic module names such as `snippet_1.` from user-visible REPL
  diagnostics.
- Added GNU readline-backed terminal input to the REPL binary, including
  up-arrow traversal of past commands.
- Added a standalone pseudo-TTY smoke test at `tests/run_repl.py` that runs
  `bin/repl`, enters an expression, presses up-arrow, presses Enter, and
  verifies the recalled command executes again.
- Added `ci.sh` to run randomized unit tests, benchmarks, and the standalone
  REPL smoke test before PRs.
- Improved function-call mismatch diagnostics so they use DMD AST/semantic
  matching to include callable signatures, including overload candidates.
- Supported import declarations as no-display REPL cells. For example,
  `import std.algorithm;` persists and a later expression can call `min`.
- Removed dead executor REPL APIs after the backend REPL path replaced them.

Remaining follow-up:

- Fix REPL display for valid CTFE results that are not currently converted to a
  user-facing value. For example, after `import std.algorithm;`,
  `[1, 2, 3].map!(x => x * 2)` currently reports
  `Unsupported CTFE eval result.`. That diagnostic is wrong: real CTFE supports
  the same operation when materialized, such as
  `static assert(func([1, 2, 3]) == [2, 4, 6]);` with a function that returns
  `ints.map!(x => x * 2).array`. Treat this as a REPL conversion/rendering bug,
  not an unsupported CTFE evaluation.

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
  - Incomplete cells are reported before backend execution so `Repl` can
    buffer more input.
  - `ReplSession` produces `ReplCell` objects for backend execution.
  - Shared expression-vs-statement/declaration handling lives here, not in
    individual backends.
- Add the public REPL coordinator in `quickbite.repl`:
  - Expose `Repl.submit(input) -> Value`.
  - `Repl` owns a `ReplSession` and a backend instance.
  - `Repl` buffers incomplete input atoms and only accepts history after a
    complete cell executes.
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
  - Use a line-editing library for terminal input so interactive sessions get
    command-history navigation.
- Tests:
  - Replace `ut.executors.repl` with `ut.backends.repl`.
  - Remove `ut.executors.repl` from `tests/main.d`.
  - Do not add subprocess REPL tests to normal `dub test`.
  - Unit-test CLI option parsing without spawning `bin/repl`.
  - Keep binary-level pseudo-TTY REPL checks in standalone scripts such as
    `tests/run_repl.py`, outside the normal unittest build.

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
- Multiline function declarations buffer until complete, then persist and can
  be called by later expression cells.
- Import declaration cells persist without display, and imported symbols are
  available to later expression cells.
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
  `int x;`, `++x;`, `x`, a multiline function declaration, a call to that
  function, and `:q` into `bin/repl` and verify expression output appears while
  no-display cells stay quiet.
- Run `tests/run_repl.py` after `dub build -c repl` to verify interactive
  terminal command history through a pseudo-TTY.
- Run `ci.sh` before preparing a PR.

## Assumptions

- Follow-up slices happen in a task-specific worktree and branch.
- This slice does not remove executor classes or unrelated executor APIs beyond
  the dead executor REPL entrypoint.
- The REPL remains CTFE-only for now, but the API must avoid CTFE-specific
  duplication so later backends can implement `evalRepl(ReplCell)`.
- The current generated expression-history strategy is preserved unless the new
  frontend session model makes it unnecessary.

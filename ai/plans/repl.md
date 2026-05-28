# Plan: REPL

## Priority Work

Pick these items up before any other REPL follow-up.

- Keep failed REPL import/eval cells from poisoning the session. For example,
  `import std;` currently reports DMD/CTFE diagnostics from `core.atomic`:
  `function
  core.internal.atomic.atomicFetchAdd!(MemoryOrder.seq, true, uint)`
  `.atomicFetchAdd has no return statement, but is expected to return a value
  of type uint`, followed by template-instantiation errors. The worse behavior
  is that none of `std` is available afterward. A failed no-display cell must
  not be accepted into REPL history, and later valid cells should still see the
  last known-good session state.
- Support C pointer values and pointer-to-integer casts in REPL cells without
  corrupting the session parser state. This currently fails after importing
  `core.stdc.stdlib`, allocating with `malloc`, casting the pointer to `int`,
  and then evaluating the variable:

  ```text
  > import core.stdc.stdlib;
  > auto ptr = malloc(42);
  > int i = cast(int) ptr;
  > i
  found `}` when expecting `;` following expression
  matching `}` expected following compound statement, not `End of File`
  >
  ```
- Support type-introspection cells such as `typeof(i)` without treating the
  type node as a normal expression result. The REPL currently reports this as
  a frontend error after a variable declaration:

  ```text
  Quickbite REPL
  > int i;
  > typeof(i)
  type `int` is not an expression
  >
  ```
- Support runtime side-effect cells such as `std.stdio.File` writes. The REPL
  currently lets the session continue after constructing a file handle and
  calling `writeln`, but no file is written. Printing the `File` value itself
  is separate `Value` work and is out of scope for this REPL plan:

  ```text
  Quickbite REPL
  > import std.stdio;
  > auto f = File("/tmp/haha.txt", "w");
  > f.writeln("hello there");
  >
  ```

  ```text
  $ cat /tmp/haha.txt
  cat: /tmp/haha.txt: No such file or directory
  ```

## Summary

The REPL uses the new backend architecture. Runtime REPL evaluation and REPL
tests must go through the backend REPL API, not executor APIs. The current REPL
is CTFE-only, but the API must stay backend-shaped so later backends can
implement the same cell protocol.

Shared frontend/session code owns parsing, classification, buffering, and
history acceptance. Backends execute complete `ReplCell` values and return
`quickbite.lang.Value`.

## Progress

Completed:

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

- Add proper range support to `Value` so REPL results can represent ranges
  directly instead of forcing them into arrays.
- Fix REPL display for valid finite range results. For example, after
  `import std.algorithm;`, `[1, 2, 3].map!(x => x * 2)` currently reports
  `Unsupported CTFE eval result.`. Until `Value` has range support, finite
  ranges may be materialized into arrays so they fit the current
  representation. This is a temporary `Value` representation workaround, not a
  CTFE-backend-specific concept. Do not implement this by rewriting REPL input
  source, appending `.array` to user expressions, or adding a display-only
  wrapper source path. Never try to materialize infinite ranges.

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
- Do not use failed REPL evaluation as control flow to distinguish expressions
  from statements/declarations or incomplete input. Exceptions are
  diagnostics/failures, not a parser API.
- Do not leave the binary on a different evaluation path than the unit REPL
  loop.
- Do not wrap REPL cells in `unittest` blocks.

## Test Plan

Use strict TDD. Before adding or modifying each test, present the exact
proposed test code and wait for approval.

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

- Run focused tests for the backend REPL module.
- Run `dub test -- --random`.
- Build the REPL configuration with `dub build -c repl`.
- Actually try the REPL binary after building it. At minimum, pipe `1`,
  `int x;`, `++x;`, `x`, a multiline function declaration, a call to that
  function, and `:q` into `bin/repl` and verify expression output appears while
  no-display cells stay quiet.
- Run `tests/run_repl.py` after `dub build -c repl` to verify interactive
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

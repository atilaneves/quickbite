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
  `bin/qb`, enters an expression, presses up-arrow, presses Enter, and
  verifies the recalled command executes again.
- Added `ci.sh` to run randomized unit tests, benchmarks, and the standalone
  REPL smoke test before PRs.
- Improved function-call mismatch diagnostics so they use DMD AST/semantic
  matching to include callable signatures, including overload candidates.
- Supported import declarations as no-display REPL cells. For example,
  `import std.algorithm;` persists and a later expression can call `min`.
- Removed dead executor REPL APIs after the backend REPL path replaced them.
- Finished REPL display for valid finite range results so it matches the DMD
  shape from `pragma(msg)`, including nested `null` values in range structs.
- Tightened the regression in `ut.backends.repl` to assert the exact rendered
  output for the finite-range case.
- Fixed `import std;` in the CTFE-backed REPL. Real CTFE accepts importing
  Phobos symbols through `import std;`; the REPL failure came from Quickbite's
  frontend-only `dmd.iasm` shim not marking functions that contain inline asm.
  That made DMD-as-a-library reject Phobos atomic helpers during semantic
  analysis with a spurious no-return diagnostic. The shim now matches DMD's
  no-backend semantic path by marking the current function as containing inline
  asm.
- Fixed piped blank input in the REPL binary. `printf "\n" | bin/qb` now exits
  successfully without invoking the evaluator, and the banner is only printed
  for terminal-backed stdin so blank piped input stays silent.
- Fixed `bin/qb -c "1 + 2"` so command evaluation prints non-void results,
  matching piped and interactive REPL evaluation.
- Fixed strings displaying as char arrays: `"hello"` prints `[h, e, l, l, o]`
  instead of `"hello"`. String results such as `to!string(42)` also display
  as quoted string values.
- Kept failed REPL eval cells from poisoning the session. A failed no-display
  cell is not accepted into REPL history, and later valid cells still see the
  last known-good session state.
- Supported type-introspection cells such as `typeof(i)` without treating the
  type node as a normal expression result.
- Fixed syntax errors exposing wrapper internals. `1 +` now reports only the
  primary diagnostic from the original REPL input instead of additional
  generated-wrapper diagnostics about `}`, `return`, or compound statements.
- Fixed duplicated runtime error messages in user-visible REPL diagnostics.
  Runtime CTFE failures such as `1 / 0` and `[1, 2, 3][10]` now report the
  DMD diagnostic once instead of repeating the same line.
- Fixed direct REPL parser calls to pass NUL-terminated source buffers. This
  keeps readline-backed interactive input from exposing stray bytes such as
  `0x7f` to DMD's parser under pseudo-TTY tests.
- Confirmed the `Function declared twice` priority item is already fixed on
  current `master`: a duplicate function declaration reports the conflict, and
  the first accepted function remains callable.
- Added a red regression for expression-cell CTFE failures losing diagnostics:
  `auto arr = [1,2,3]; arr[99]` currently reports
  `Unsupported CTFE eval result: error` instead of DMD's bounds diagnostic.
- Fixed expression-cell CTFE failures so DMD's diagnostic is reported before
  `ErrorExp` reaches REPL value rendering. For example,
  `auto arr = [1,2,3]; arr[99]` reports DMD's bounds diagnostic.
- Fixed whitespace-only piped input in the REPL binary. `printf "   \n" |
  bin/qb` now exits successfully without invoking the evaluator, matching
  blank piped input.
- Displayed numeric scalar values using D literal notation where a
  distinguishing suffix exists: `42u` (`uint`), `42L` (`long`), `42UL`
  (`ulong`), and `3.8f` (`float`). Default D literal types now display
  without annotation (`int` as `42`, `double` as `3.8`), while types with no D
  literal suffix keep `: type` annotations (`byte`, `short`, `ubyte`,
  `ushort`, `real`).
- Fixed `bin/qb tests/example.d` so file arguments load through the normal DMD
  module parser. This accepts module-level declarations and `unittest` blocks
  without running the unittest blocks yet.
- Added `:t` to run accepted REPL `unittest` cells and loaded-file
  `unittest` blocks. The command reparses loaded unittest source with
  `parseModuleWithCheckActionContext` before handing it to the backend, so
  assertion failures report DMD-style context messages such as `1 != 2`.
- Fixed `iota(5).filter!(x => x % 2 == 0).array` producing no output and no
  error. The frontend now classifies this valid expression-shaped cell through
  DMD statement parsing instead of accepting DMD's prototype-shaped module
  parse as an incomplete/no-display cell, so the result displays as
  `[0, 2, 4]`.
- Confirmed template function definitions work as no-display cells and added a
  regression for `T identity(T)(T x) { return x; }` followed by `identity(42)`.
- Fixed file-argument execution so `bin/qb tests/example.d` exits after
  loading the file instead of entering the interactive REPL prompt when stdin
  is a terminal.
- Added structured backend test results and used them for REPL `:t`
  diagnostics. Failing REPL unittest blocks now report the unittest location,
  such as `unittest at <repl>(1) failed: 1 != 2`, while existing raw backend
  failure-message callers keep their old messages.
- Added DMD-generated unittest symbol names to structured backend test case
  results. The CTFE backend now reports DMD names such as
  `__unittest_L2_C13` directly rather than inspecting unit-threaded
  attributes.
- Preserved actual source file names in structured backend test case locations
  for file-backed fixtures by parsing files through a file-path-aware frontend
  API instead of synthetic snippet names.

Remaining follow-up:

- Expand the structured backend test-result API so running tests reports what
  ran and what failed. Keep `runParsedTests` as a compatibility wrapper until
  callers migrate, but future REPL, summary, and reporting work should consume
  structured results rather than throwing or parsing raw strings.

- Keep source loaded from files from advancing typed REPL snippet locations.
  For example, after `loadModuleSource("int loadedValue() { return 41; }\n")`
  and a typed `unittest { assert(1 == 2); }`, `:t` should report
  `unittest at <repl>(1) failed: 1 != 2`, not a later line caused by the
  loaded source. File-backed code should eventually keep its own file/line
  identity instead of being appended to the synthetic REPL module.

- Prefix non-unittest interactive REPL command failures with an error label,
  preferably styled red for terminal output. For example, after a command
  failure the output should not be only the raw backend diagnostic.

- For red terminal error labels, add a small DUB dependency that renders ANSI
  colour only when the output stream is a terminal. Test the actual colour in
  the standalone pseudo-TTY path, not normal `dub test`: extend
  `tests/run_repl.py` to enter a failing command such as `:t` after a failing
  `unittest` cell, then assert the captured TTY output contains the red SGR
  sequence around the `Error:` label and still omits colour for piped output.

- Support several file arguments. `bin/qb a.d b.d` should execute or
  interpret all files in argument order, not only the first file.

- Add `-l` so file arguments can leave the session live after execution.
  Without `-l`, file arguments should execute and exit. With `-l`, the REPL
  should start after executing the files, with the same effective session state
  as if the user had pasted the code manually, except that loaded code remains
  in its original modules.

- If any additional `Value` shape work is needed, keep it generic to the
  representation rather than CTFE-specific. Do not rewrite REPL input source,
  append `.array` to user expressions, or add a display-only wrapper source
  path. Never try to materialize infinite ranges.
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

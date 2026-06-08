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

## Done

- Silently skip comment-only lines instead of erroring. The piped CLI loop,
  interactive CLI loop, and `runReplLoop` now skip blank, whitespace-only,
  and `//` comment-only input before submitting to DMD.

- Continue past errors in piped mode instead of exiting on the first
  failure. The interactive REPL uses `FailureMode.continue_` and keeps
  running after an error; the piped path uses `FailureMode.exit` and
  terminates immediately, silently dropping all remaining input. Python
  and GHCi both continue past per-line errors in non-interactive mode.
  The two modes should be consistent.

  Offending code (`repl/main.d:48–49`):

  ```d
  if (!submit(repl, line, FailureMode.exit))
      return 1;
  ```

  Reproducer:

  ```sh
  printf '1 + 1\n2 + 2\nbad_var\n4 + 4\n5 + 5\n' | bin/qb
  ```

  Current output (lines after the error are dropped):

  ```text
  2
  4
  Error: undefined identifier `bad_var`
  ```

  Expected:

  ```text
  2
  4
  Error: undefined identifier `bad_var`
  8
  10
  ```

- Clear buffered incomplete input after a buffered cell completes with a
  diagnostic. A failed multiline declaration such as a function with an
  undefined identifier no longer appends later submissions to the rejected
  source.

- Define command handling while input is pending. Commands such as `:q` must
  not silently abandon a buffered D cell in the binary path unless the API path
  models the same explicit command behavior.
  `Repl` now rejects REPL commands while a D cell is buffered, keeps the
  buffered source intact, and exposes the valid quit-command check used by both
  `runReplLoop` and the CLI loops.

  Offending input:

  ```text
  int f() {
  :q
  return 42;
  }
  f()
  ```

- Generalise incomplete-input detection beyond function declarations. Partial
  structs, enums, templates, and other declarations should buffer until they
  are complete instead of becoming hard syntax errors.

  Offending code (`source/quickbite/frontend/cell.d:549-553`):

  ```d
  result = moduleResult.diagnostics.hasErrors &&
      moduleResult.module_.members !is null &&
      moduleResult.module_.members.length != 0 &&
      allFunctionDeclarations(moduleResult.module_.members) &&
      hasDiagnosticAtEnd(input);
  ```

  Reproducer:

  ```text
  struct S {
  int x;
  }
  S(42)
  ```

  Current output:

  ```text
  Error: `}` expected following members in `struct` declaration
  ```

- Require type-expression classification to consume the whole input. A cell
  that starts with a type expression but has trailing tokens must not be
  rewritten through the `.stringof` type-display path.

  Offending code (`source/quickbite/frontend/repl.d:93-97`):

  ```d
  const expression = parser.parseExpression;
  result = expression !is null &&
      expression.isTypeExp !is null &&
      parser.token.value != TOK.semicolon &&
      global.errors == 0;
  ```

  Reproducer:

  ```sh
  bin/qb -c 'typeof(1) + 2'
  ```

  Current output:

  ```text
  Error: CTFE internal error: non-constant value `int`
  `(int) + 2` cannot be interpreted at compile time
  ```

- Recognise standalone `mixin(…)` as an expression cell. `isExpressionCell`
  now accepts a complete DMD `MixinStatement` node as displayable REPL input,
  so `mixin("1 + 2")` evaluates through the expression path and displays `3`.

- Extend type-expression display to cover type aliases and user-defined
  types, not only primitive type keywords. REPL type-expression
  classification now checks the current session module context with a
  DMD-resolved synthetic alias probe, so built-in aliases such as `string`,
  user aliases such as `MyInt`, and user-defined types such as `Widget`
  display through the `.stringof` path.

- Suppress `pragma(msg, …)` output during cell classification and
  ensure it fires exactly once during evaluation on stderr. Standalone
  `pragma(msg)` cells are recognised through DMD's parsed
  `PragmaStatement` node and are no longer appended to the persistent REPL
  transcript, so later cells do not re-run their compile-time message.

- Verified `std.format.format` in the REPL against the shell-safe
  reproducer. The earlier reproducer used shell `printf` with `%s` in
  the format string, so the shell stripped the placeholder before `qb`
  saw the input and produced `format("hello ", 42)`, which correctly
  leaves an orphan argument. Passing a literal `%s` to `qb` evaluates
  like DMD CTFE and prints `"hello 42"`.

  Shell-safe reproducer:

  ```sh
  printf '%s\n%s\n' \
    'import std.format : format;' \
    'format("hello %s", 42)' |
    bin/qb
  ```

  Output:

  ```text
  "hello 42"
  ```

  DMD CTFE:

  ```d
  import std.format : format;
  enum s = format("hello %s", 42);  // "hello 42" — no error
  ```

## To do

- Drop the trailing `null` from lazy-range struct display. DMD
  `pragma(msg)` omits the function-pointer field (which holds the
  lambda and has no compile-time representation); the REPL's `Value`
  display path includes it as `null`. This is a display deviation from
  the canonical DMD output the plan Goal commits to matching.

  Reproducer:

  ```sh
  printf 'import std.algorithm : map;\n[1,2,3].map!(x => x*2)\n' | bin/qb
  ```

  Current output:

  ```text
  MapResult([1, 2, 3], null)
  ```

  DMD `pragma(msg)` output:

  ```text
  MapResult([1, 2, 3])
  ```

- Collapse duplicate import-path lines in failed-import diagnostics.
  DMD emits `import path[N] = …` once, after the error. The REPL
  currently prints it twice and before the error message because
  `withoutConsecutiveDuplicateLines` (`source/quickbite/repl.d:228`)
  deduplicates on the raw DMD text where the two identical lines are
  separated by a non-identical "Expected … in one of the following
  import paths:" line; after the surrounding lines are stripped the
  duplicates become adjacent but deduplication has already run.

  Offending code (`source/quickbite/repl.d:228`):

  ```d
  private string withoutConsecutiveDuplicateLines(in string diagnostic)
  @safe pure {
      // deduplication runs on the raw diagnostic before any stripping
      // ...
  }
  ```

  Reproducer:

  ```sh
  printf 'import mymodule;\n' | bin/qb
  ```

  Current output:

  ```text
  import path[0] = /usr/include/dlang/dmd
  import path[0] = /usr/include/dlang/dmd
  Error: unable to read module `mymodule`
  ```

  Expected (matches DMD):

  ```text
  Error: unable to read module `mymodule`
  ```

- Make `:t` with no loaded tests produce a clean REPL result. It should not
  leak DMD import-path diagnostics or report that `<repl>` cannot be found.

  Offending command:

  ```sh
  bin/qb -c ':t'
  ```

  Current output includes:

  ```text
  import path[0] = /usr/include/dlang/dmd
  Error: cannot find input file `<repl>`
  ```

- Route all `loadModuleFile` errors through the REPL CLI diagnostic
  path. Currently any exception thrown from `repl.loadModuleFile` —
  whether from `readText` (missing file), `parseModule` (duplicate
  symbol), or elsewhere — escapes the uncaught-exception handler in
  `main.d` and prints a raw D stack trace. The duplicate-file case
  additionally leaks unsanitised `snippet_N` names because the
  exception bypasses `userDiagnostic`.

  Offending code (`repl/main.d:25–28`) — no try-catch around file loading:

  ```d
  if (options.options.hasFile) {
      foreach (file; options.options.files)
          repl.loadModuleFile(file);  // any exception escapes here
  }
  ```

  Reproducers:

  ```sh
  bin/qb /tmp/does-not-exist.d          # missing file
  bin/qb /tmp/test.d /tmp/test.d        # duplicate load
  ```

  Current output (duplicate load):

  ```text
  object.Exception@source/quickbite/frontend/compiler.d(348):
  function `snippet_1.answer()` conflicts with previous declaration …
  ----------------
  … (full D stack trace) …
  ```

  Expected: a concise `Error:` diagnostic, no stack trace, no
  synthetic names.

- Add an intentional diagnostic or placeholder for CTFE results that Quickbite
  cannot display yet. Do not expose backend conversion internals such as
  `Unsupported CTFE eval result: function_`; something like
  `<undisplayable>` is enough until the value model supports the result.

  Offending command:

  ```sh
  bin/qb -c 'delegate int(){ return 42; }'
  ```

  Current output:

  ```text
  Error: Unsupported CTFE eval result: function_
  ```

- Make `__FILE__`, `__FUNCTION__`, and `__MODULE__` return
  user-meaningful values instead of internal synthetic names. DMD CTFE
  reflects the real source context; the REPL currently leaks wrapper
  internals because `userDiagnostic` sanitises exception text but the
  same substitution is never applied to `Value` results.

  Offending code (`source/quickbite/repl.d:210-226`) — sanitisation
  only fires on error message strings, not on evaluated values:

  ```d
  private string userDiagnostic(in string diagnostic) @safe pure {
      string result;
      size_t index;
      while (index < diagnostic.length) {
          const replacement = syntheticNameReplacement(diagnostic[index .. $]);
          // ...
      }
      return withoutConsecutiveDuplicateLines(result);
  }
  ```

  Reproducer:

  ```text
  __FILE__
  __FUNCTION__
  __MODULE__
  ```

  Current output:

  ```text
  "snippet_0.d"
  "snippet_1.f"
  "snippet_2"
  ```

  Expected (approximate):

  ```text
  "<repl>"
  "<repl>"
  "<repl>"
  ```

- Rename the REPL wrapper function away from `f` so that user-defined
  functions at module scope cannot collide with it. Any fixed single name
  just shifts the reserved name. The fix must use an unspeakable synthetic
  name — e.g. an ever-incrementing counter suffix like
  `__quickbite_repl_eval_0__` — and sanitise it in error messages the same
  way `snippet_N` is sanitised today. Compare Python (`eval`/`exec` into a
  namespace dict — no wrapper needed) and GHCi (direct evaluation — no
  wrapper needed); in both cases the user namespace is never polluted by a
  synthetic function name.

  Offending code (`source/quickbite/frontend/cell.d:630`):

  ```d
  private string evalSource(
      in string moduleTranscript,
      in string localTranscript,
  ) {
      return moduleTranscript ~ "auto f() { " ~ localTranscript ~ " }";
  }
  ```

  Reproducer:

  ```text
  int f() { return 1; }
  f()
  ```

  Current output:

  ```text
  Error: function `f()` conflicts with previous declaration at <repl>(1)
  ```

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

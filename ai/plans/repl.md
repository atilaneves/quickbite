# Plan: REPL

## Handoff (2026-05-25, in-progress worktree)

### What is done

- `Value` struct in `source/quickbite/executor.d` redesigned to use
  `SumType!(bool, byte, ubyte, short, ushort, int, uint, long, ulong)`.
  Each D integral type is preserved exactly — no normalisation to `long`.
  `Value(3u) != Value(3L)`, `Value(3) != Value(3L)`, etc.
- `eval(in string input) -> Value` implemented on four backends:
  - `treeWalking`: wraps input as `void f() { <prior> auto __r =
    <last>; }`, parses via DMD frontend, walks AST with existing
    `runStatement`/`runExpression`, returns `Value(cast(int) result)`.
    Also added subtract, multiply, divide, cast, blit, addAssign, and
    minAssign handlers to `runExpression`.
  - `treeWalkingOld`: same wrapping strategy, delegates to internal
    `Interpreter.executeFunction`.
  - `dmdCtfe`: wraps as `auto f() { return <last>; }`, finds `f`,
    builds a `VarExp`/`CallExp`, calls `ctfeInterpret`, extracts
    `getInteger()`.
  - `ir`: wraps as `auto f() { return <last>; }\nunittest { f(); }`,
    lowers via `lowerModule`, executes via `executeFunction`.
  - `dmdCodegen`: throws `Exception("eval not yet implemented for
    dmdCodegen")`. A separate worktree is implementing this backend
    more broadly; `eval` will be added there.
- `tests/ut/repl.d` — five eval tests parameterised over the four
  implemented backends (`dmdCodegen` excluded via `static if`):
  `add0`, `add1`, `add2`, `arithmetic` (five runtime cases covering
  +, -, *, /), `multiCell`. 560 tests, all pass.
- `dub.sdl` has a `repl` configuration that builds `bin/repl`.
- `repl/main.d` is now an interactive executable:
  - no args starts a REPL with banner `Quickbite REPL` and prompt `> `;
  - `-c <code>` evaluates code silently, following Python's precedent
    that command mode has no implicit expression display;
  - `Exception`s from `eval` are printed as diagnostics and the REPL
    continues;
  - `Error`s are printed and terminate the process with status 1.
- `source/quickbite/repl.d` exposes `runReplLoop`, which currently:
  - takes a real `Executor`;
  - evaluates each input atom independently;
  - returns one output string per expression value;
  - stops on `:q` or `:quit`.
- `Value.toString` exists for displaying integral and bool values.
- Binary integration tests have already proven basic executable wiring.
  Do not add more subprocess coverage for REPL behavior.
- `tests/ut/repl.d` still has older binary smoke tests. Do not add more.
  New REPL behavior must be unit-tested through `runReplLoop` or smaller
  helpers.
- The next approved `runReplLoop` test has already been added:
  `["int x;", "x", ":q"]` should display only `["0"]`. It was approved
  before editing and originally failed red against the old `eval` API.
- `source/quickbite/executor.d` now has a structured REPL API:
  `Repl.CellResult` with `Repl.CellStatus.incomplete`, `void_`, and `value`.
  `Executor` now exposes
  `evalReplCell(in string transcript, in string input)`.
- `source/quickbite/repl.d` now keeps a transcript and branches only on
  `Repl.CellStatus`. The `with` around the status switch is intentional.
  Do not use `with` for tiny one-off blocks, but keep it for these switches
  so enum names stay short.
- Value cells are now replayed into the transcript as generated local
  declarations, e.g. `auto __quickbite_repl_value_N = x++;`. This keeps
  expression side effects visible to later cells without triggering DMD's
  "no effect" diagnostic for plain literal expressions.
- The IR backend has an initial `evalReplCell` implementation. It classifies
  expression cells, delegates expression cells to `eval(transcript ~ input)`,
  and runs statement/declaration cells through:
  `unittest { auto f() { <transcript><input> } f(); }`.
- `repl/main.d` has been rewired to call `evalReplCell` and maintain the same
  transcript state as `runReplLoop`. The previous interactive executable still
  called `active.eval(line)`, which is why manual input such as `int x;` kept
  failing even after the unit-loop work.
- `source/quickbite/frontend/compiler.d` initializes DMD identifier character
  lookup tables. This fixed a segfault hit when the REPL used a raw DMD
  `Parser` for cell classification.
- Commits of note in `worktree-repl`:
  - `c21acf4 Make REPL interactive`
  - `1ddfa37 Keep REPL alive after diagnostics`
  - `f0a63d7 Avoid subprocess REPL tests`
  - `9aa1f4d Revert "Persist REPL declaration cells"`
- Last known green state during this in-progress edit: `dub test` passed with
  564 tests after adding the approved declaration persistence test and the
  first structured API wiring. That was before the latest parser-classifier
  change described below.
- `ParseStatementFlags` is imported from `dmd.parse`, which is where the
  local DMD package exports it.
- Verification after this update: focused REPL loop tests pass, the manual
  `int x; x; x++; x` smoke test prints `0`, `0`, `1`, and the remaining PR
  gate is a full `dub test` plus `benchmarks/run.sh`.

### What is fake

- The REPL loop is still intentionally minimal. It does not yet handle
  backend selection, completeness, continuation prompts, or stateful
  session accumulation.
- `repl/main.d` reads lines directly from `stdin`. It should be replaced
  by the planned line-input abstraction before adding serious interactive
  editing behavior.
- Value cells are appended as generated local declarations. This is still a
  minimal transcript strategy and should later move behind a structured
  frontend-owned session representation.
- `incomplete` exists in the API but is not actually implemented yet.
- Non-IR backends only have compatibility `evalReplCell` stubs that call
  `eval(transcript ~ input)` and return `value`.
- `dmdCodegen.eval` is still not implemented.

### Bad approach reverted

- Commit `7c352ce Persist REPL declaration cells` was reverted by
  `9aa1f4d` because it made `runReplLoop` inspect user D code with a
  semicolon heuristic.
- Do not reintroduce delimiter-counting, suffix checks such as
  `endsWith(";")`, or other poor-man parsing in the REPL loop.
- Do not use exceptions for normal REPL control flow. Exceptions are for
  diagnostics/failures after the frontend/eval layer has been asked a
  well-defined question, not for deciding whether input is an expression
  or a statement.
- The REPL loop must not decide D syntax. Classification, completeness,
  and expression-vs-statement/declaration handling belong behind the
  frontend/`Executor` API.
- Do not leave the binary on a different evaluation path than the unit REPL
  loop. The interactive executable must keep using the same structured cell
  API or manual testing will not match unit behavior.

### What comes next

Use strict TDD and stop for approval before each new or modified test.
Do not add more binary/process tests unless explicitly requested. Future
REPL behavior must be driven by unit tests around `runReplLoop` and
supporting helpers, using real executors and no `executeShell`,
`execute`, `pipeProcess`, or similar per-test process spawning.

Immediate continuation after this PR:

1. Implement real parsed `incomplete` status and continuation prompts.
2. Move `repl/main.d` onto the planned line-input abstraction.
3. Add backend selection parsing shared with benchmark tooling.
4. Add backend replay/switching only after transcript replay works through
   the structured API.

Later slices:

1. Implement real parsed `incomplete` status and continuation prompts.
2. Fix session accumulation for all cell kinds, including expression history
   that later cells can refer to without breaking expression wrapping.
3. Move `repl/main.d` onto the planned line-input abstraction.
4. Backend selection parsing shared with benchmark tooling.
5. Implement structured REPL cells for non-IR backends.
6. `Value` support for more D result types as tests require.

### Structured eval direction

Do not continue the old "split by last newline and wrap the last line as an
expression" design. That approach cannot correctly support declarations,
imports, aliases, multi-line constructs, or incomplete input.

The current worktree has started this by adding `Executor.evalReplCell` and
`Repl.CellResult`. Continue moving the implementation toward a frontend-owned
REPL cell API that parses the accumulated session source plus the current
buffered cell and returns a structured result:

- `incomplete` when the frontend recognizes a valid but unfinished D fragment;
- `void_` when a complete statement/declaration/import/alias cell ran without
  a display value;
- `value(Value)` when a complete expression cell produced a display value.

The REPL loop should only branch on that result. It should not inspect
delimiters, keywords, braces, or semicolons in user code.

The first backend slice is in progress for IR. Reuse the existing
parser/lowering path, but keep the expression-vs-declaration decision inside
the frontend/eval layer where the parsed AST is available.

### Important: use a stronger model for the implementer

The `tdd-implementer` agent defaults to Haiku, which cannot
navigate the DMD AST API and repeatedly falls back to fakes.
For the eval implementation step, override the model to Sonnet:

```
Agent(subagent_type: "tdd-implementer", model: "sonnet", ...)
```

### What comes next after structured eval

1. Wire continuation prompts to the structured `incomplete` result.
2. Move `repl/main.d` onto the planned line-input abstraction.
3. Add backend selection parsing shared with benchmark tooling.
4. Add backend replay/switching only after transcript replay works through
   the structured API.

---

## Context

Quickbite can already parse and execute D code through multiple backends.
A REPL exposes this capability interactively: the user types D
expressions and statements, sees results immediately, and can switch
backends at runtime to compare behaviour or performance across
implementations.

## Goal

Add a `repl` dub configuration that builds a standalone REPL executable.
The REPL evaluates D expressions and statements, printing the result of
each expression. Top-level declarations, imports, aliases, functions,
types, and variables persist across later cells. The active backend is
selectable via a CLI flag at startup and switchable during the session
with an in-REPL command.

## Design

### Entry Point

The REPL builds as a standalone executable. It accepts the same backend
names as the existing CLI/benchmark tooling, so users do not learn a
separate backend vocabulary.

### Line-reading abstraction

The REPL does not call the chosen input library directly. A dedicated
line-input module owns the dependency and exposes a
library-agnostic interface. It must distinguish EOF/Ctrl-D from an empty
submitted input. All REPL logic calls only this interface.

`linenoise` is a reasonable initial implementation choice, but not a
requirement. The important requirement is that swapping to readline,
editline, `std.stdio`, or another input source later only requires
changing the line-input module.

### REPL Loop

The line reader returns submitted input atoms. When there is no buffered
D input, submissions starting with `:` are handled as REPL commands
before calling `eval`. Inside a multi-line D buffer, colon-prefixed text
is treated as D input. Unknown colon commands produce REPL diagnostics,
not frontend diagnostics.

For D input, the loop buffers submitted input atoms and calls `eval`
with the buffered text after each submitted D input atom. Like Python,
only a frontend-recognized incomplete input shows the continuation prompt
and reads another input atom. Invalid D input is a diagnostic, not an
incomplete input. The loop must not decide D completeness with
delimiter-counting or other string heuristics. The loop calls
`isComplete` after each atom; only when complete does it call `eval` and
print the result or diagnostic.

The interactive loop catches `Exception`s from `eval` and prints
diagnostics. User code failures are REPL results, not process failures.
`Error`s are printed and terminate the REPL.

Ctrl-C cancels the current buffered input, or interrupts the running
cell when evaluation is in progress, and returns to the primary prompt
when possible. Ctrl-D exits the REPL.

Prompt: `> `. Continuation prompt: `... `.

### Expression / Statement Evaluation

The REPL maintains an input history. Each history entry is one submitted
D input atom: whatever D text is in the prompt buffer when the user hits
Enter. The atom may contain multiple lines if the line editor supports
multi-line input. Colon commands are REPL commands, not input atoms, and
are excluded from input history and replay. Line-editing actions such as
arrow-key navigation are not REPL input. Replay re-submits these input
atoms in order, as if the user had typed each atom and pressed Enter
again.
Incomplete buffered input canceled by Ctrl-C is not recorded in history.

Session state persists across cells: later cells can refer to earlier
top-level declarations, imports, aliases, functions, types, and
variables.

That transcript is the source of truth for session state: replaying the
history from the beginning must reconstruct the same state for a
backend, as if the user had started fresh and typed the same inputs.
Backend switching replays the history from the beginning on the target
backend. Replay is used to reconstruct behavior relevant to future
user-observable results; internal state and non-observed side effects
are not compared directly. Replay during backend switching is silent:
prior output is not printed again. The REPL checks that the
user-observable output or result that would have been printed matches
the current backend. If an input throws an `Exception` during replay,
compare the diagnostic text that would have been printed, then continue
replay.

Do not use `Executor.runTests` directly for result-producing cells. That
API returns `void`, and Quickbite currently has no stdout-capture or
expression-value channel. Two methods are added to the `Executor`
interface in `source/quickbite/executor.d`:

- `isComplete(in string input) -> bool` — returns whether `input` is
  a syntactically complete D fragment. The REPL loop calls this after
  each submitted atom to decide whether to show `... ` or evaluate.
- `eval(in string input) -> Value` — evaluates `input` and returns the
  result. `input` is the full accumulated session source (all prior
  cells concatenated with the current cell). The REPL never passes a
  separate context parameter; it builds the full source itself. `Value`
  is a D value: the actual typed result of an expression (integral
  types normalised to `long`), or void for statements and declarations.

The REPL loop displays expression results by calling
`std.conv.text(value)` on the `Value`; `eval` never produces strings.
Syntax errors and runtime failures are reported by thrown `Exception`s.

The interactive loop owns prompts, line buffering, colon-command
dispatch, and printing returned values or diagnostics.

### Backend Selection

- `--backend=<name>` CLI flag sets the initial backend (default `ir`).
  Accepted names mirror those in the benchmark tool: `ir`,
  `treeWalkingOld`, `treeWalking`, `dmd-ctfe`, `dmd-codegen`.
- `:backend <name>` in-REPL command switches the active backend. To
  switch, replay the input history on the new backend. The goal is that
  the new backend ends up in the same observable state as the old one —
  equivalent to starting a fresh session and typing the same inputs. If
  replay fails or the resulting user-observable state differs from the
  current state, keep the current backend and print a diagnostic.

The string-to-backend mapping currently inlined in `benchmarks/main.d`
must be extracted to `source/quickbite/cli.d` and shared by both the
benchmark and REPL executables.

### In-REPL Commands

- `:backend <name>` — switch active backend
- `:backends` — list available backends
- `:reset` — clear D input history and session state
- `:show` — print the submitted D input-atom history, excluding colon
  commands
- `:help` — show command list
- `:quit` / `:q` / Ctrl-D — exit

Future improvement: add `:type <expr>` / `:t <expr>` to print the D
type of an expression.

Future improvement: add file/session commands such as `:load`,
`:reload`, or `:run` for loading D source into the REPL session.

### Key Files

- `repl/main.d` — entry point, CLI parsing, REPL loop, command dispatch
- line-input module — library-agnostic line-reading boundary
- `source/quickbite/executor.d` — add `eval` to the `Executor` interface
- `source/quickbite/cli.d` — shared string-to-backend mapping (extracted
  from `benchmarks/main.d`)
- `dub.sdl` — new `repl` configuration with a library dependency such
  as `linenoise`

Use the public `quickbite.executor(ExecutorBackend)` factory for backend
instantiation after parsing backend names through `cli.d`.
REPL cells go through `Executor.eval`, not `Executor.runTests`.

## Methodology

Strict TDD. Each new behaviour is earned by a failing test first. Tests
live in `tests/ut/` alongside the existing suite (or a dedicated
`tests/ut/repl.d`).

## Verification

Build: `dub build -c repl`

Manual smoke test:
```
./repl
> 1 + 2
3
> int x = 10;
> x * x
100
> if (x)
... x += 1;
> int y =
diagnostic: parse error
> :backend treeWalking
backend: treeWalking
> x * 2
20
> assert(1 == 2);
core.exception.AssertError: Assertion failure
> :backend ir
backend: ir
> :q
```

Run the full test suite: `dub test`

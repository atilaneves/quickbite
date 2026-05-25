# Plan: REPL

## Handoff (2026-05-25)

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
- `repl/main.d` is a minimal executable that reads all stdin lines,
  runs them through the shared loop, and writes returned expression
  values to stdout.
- `source/quickbite/repl.d` exposes `runReplLoop`, which currently:
  - takes a real `Executor`;
  - evaluates each input atom independently;
  - returns one output string per expression value;
  - stops on `:q` or `:quit`.
- `Value.toString` exists for displaying integral and bool values.
- Binary integration tests have already proven basic executable wiring.
  Do not add more subprocess coverage for REPL behavior.
- `tests/ut/repl.d` has the first unit-level REPL loop test:
  `repl.loop.evaluatesExpressionCellsUntilQuit`. It uses the real IR
  executor, passes `["1", "2", ":q"]` to `runReplLoop`, and expects
  `["1", "2"]`.
- Last verification: `dub test` passed with 562 tests.

### What is fake

- The REPL loop is still intentionally minimal. It does not yet handle
  prompts, diagnostics, command-mode execution, backend selection,
  completeness, or stateful session accumulation.
- `repl/main.d` buffers stdin into an array before running the loop.
  This is acceptable for the current tests but should be replaced by a
  streaming line-input abstraction when prompts/completeness are added.
- Expression cells are evaluated independently. Statement/declaration
  cells and no-result values are not supported yet.
- `dmdCodegen.eval` is still not implemented.

### What comes next

Use strict TDD and stop for approval before each new or modified test.
Do not add more binary/process tests unless explicitly requested. Future
REPL behavior must be driven by unit tests around `runReplLoop` and
supporting helpers, using real executors and no `executeShell`,
`execute`, `pipeProcess`, or similar per-test process spawning.

Recommended next approved test:

1. A unit test for `:quit` as the long-form quit command:
   `runReplLoop(executor(ExecutorBackend.ir), ["1", ":quit", "2"])`
   returns `["1"]`.

After that, likely next slices are:

1. Backend selection parsing shared with benchmark tooling.
2. Command-mode execution (`-c`) with no implicit echo.
3. Session accumulation across cells.
4. `Value` support for D `void` / no-result cells.
5. Parsed completeness status, not string heuristics.

### How to implement real eval

Wrap the input in a function that captures the last expression:

```d
const lastNl = input.lastIndexOf('\n');
const prior  = lastNl < 0 ? "" : input[0 .. lastNl + 1];
const last   = lastNl < 0 ? input : input[lastNl + 1 .. $];
const source = "void f() { " ~ prior ~ "auto __r = " ~ last ~ "; }";
```

Parse `source`, walk/execute the function body. For the
tree-walking backends, run all statements via `runStatement`
then call `runExpression` on `__r`'s initializer. For the CTFE
backends (`dmd_ctfe`, `dmd_codegen`), follow the `VarExp` /
`CallExp` / `ctfeInterpret` pattern already in
`ctfeFailureMessage`. For the IR backend, `lowerModule` then
call `executeFunction("f", ...)`.

### Important: use a stronger model for the implementer

The `tdd-implementer` agent defaults to Haiku, which cannot
navigate the DMD AST API and repeatedly falls back to fakes.
For the eval implementation step, override the model to Sonnet:

```
Agent(subagent_type: "tdd-implementer", model: "sonnet", ...)
```

### What comes next after real eval

1. Implement `isComplete(in string input) -> bool` on `Executor`
   (the REPL loop calls this to decide whether to show `> ` or
   `... `).
2. Build the REPL executable: `repl/main.d`, line-input module,
   `dub.sdl` `repl` configuration.
3. The REPL accumulates all prior cell inputs and passes the full
   accumulated source to `eval` on each new cell. No `context`
   parameter — the full accumulated source is the input.

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
delimiter-counting or other string heuristics. The loop calls `isComplete` after each atom; only when complete does
it call `eval` and print the result or diagnostic.

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

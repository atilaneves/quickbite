# Plan: REPL

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
delimiter-counting or other string heuristics. Once `eval` returns any
tag other than `incomplete`, the loop prints the result or diagnostic.

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
expression-value channel. Add an `eval` method to the `Executor`
interface following the Python `runsource` / GHCi model: it accepts the
current session context and the buffered input so far, and returns a
discriminated union with three cases:

- `incomplete` — the input is a valid but unfinished D fragment; the
  loop shows `... ` and reads another line
- `void_` — the cell ran to completion with no display value
- `value(string display)` — the cell produced a displayable result

Expression values are displayed with D's normal string conversion:
`std.conv.text(value)`. Statements and declarations that produce no
display value return `void_`.

This collapses completeness checking and evaluation into one call. The
loop never inspects D syntax itself: it calls `eval` with the buffered
D input and branches on the returned tag. Syntax errors and runtime
failures are reported by thrown `Exception`s.

`eval` owns D cell completeness checks, evaluation, and session-context
updates. The interactive loop owns prompts, line buffering,
colon-command dispatch, and printing returned values or diagnostics.

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

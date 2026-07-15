# Goal

Write a bytecode VM for the D programming language.

# Design

Optimise for unittest result latency from any edit — this overrides all other
concerns. JIT would improve runtime but tests run in milliseconds; JIT compile
time would dominate.

Avoid the linker tax: no object files, no whole-program compilation. Drive
compilation from unittest blocks; generate only the bytecode needed for each
test and its transitive dependencies.

Keep code isolated from dmd internals behind a stable interface that wraps
dmd-as-a-library.

# Plan

Consult `ai/plans` for implementation plans.

When parallel work tracks are running (e.g. the bytecode rewrite, the
value/formatter track, the interpreter FFI track), append progress and
ledger notes only to the plan that owns your track — bytecode work to
`ai/plans/bytecode.md`, formatter/display work to `ai/plans/value.md`,
FFI work to `ai/plans/ffi.md`. A cross-track observation goes in your
own plan with a reference to the other, not as an edit to the other
plan. This keeps concurrent PRs from conflicting in the plan ledgers.

# Coding Guidelines

## Git worktrees

Do work in a git worktree unless instructed otherwise. Name worktrees
the same as their branch, e.g. worktree named "foo" →
`./worktrees/foo` at repo root. Always use the `worktrees` directory
in this repo unless instructed otherwise.

## TDD

Strict TDD: failing test → dumbest passing code → green suite. No refactoring
until all tests pass. Ask for feedback after the refactoring step.

Stop and wait for approval before adding or modifying any test. `SystemLinker`
(compiled D) is the single behaviour oracle for every backend except `Ctfe`
(`ai/plans/single-oracle.md`). Promoting an already-existing backend-matrix
test to another backend is pre-approved when the test is backed by that oracle.
`lang/` holds the hermetic language surface: behaviour that needs nothing from
the host. `sys/` holds behaviour that needs the runtime environment
(libc/OS — today `cstdlib`, `file`, `random`, `concurrency`). The directory
criterion is what the behaviour *needs from the host*, never whether `Ctfe`
can execute it: CTFE-expressibility is a per-backend capability that belongs
in the fixture's matrix, not the directory. Every backend except `Ctfe` is a
promotion candidate. Adding a new test or changing test behaviour still
requires approval.

A fixture's backend list is `Matrix!(...)` (`tests/ut/backends/package.d`),
defaulting to every mature backend (`LangBackends`/`SysBackends`). A mature
backend opts out with a reason: `Matrix!(Omit!(B, Because.inexpressible,
"..."))`, `Because.diverges`, or `Because.refusal` (see
`ai/plans/interpreter.md` §8) — each carries a required `note` explaining why
except `Because.unconfirmed`, which marks the promotion backlog. Promoting a
backend is deleting its `Omit!(B, Because.unconfirmed)`. Hand-written
`AliasSeq!(...)` is reserved for characterization pins that never carry a
`SystemLinker`-oracle expectation (e.g. pinning `Ctfe`'s actual, divergent
behaviour). Backend-mechanism tests (native JIT internals, FFI dependency
images, ORC/ELF plumbing) live with their subsystem, not under `runner/`.

Test behaviours, not implementations.

Language-surface tests must match D's compiled-code behaviour, with
`SystemLinker` as the oracle (`ai/plans/single-oracle.md`). If a backend
disagrees with `SystemLinker`, the backend or test is wrong. `Ctfe` is not an
oracle: where it diverges from `SystemLinker`, pin `Ctfe`'s actual behaviour as
a characterization test (with a comment naming the divergence) rather than
treating it as truth. `Ctfe` is still a convenient real-D fixture source — a
fixture written for it is real D — but it never arbitrates correctness.

## Style

### General

* One True Brace Style. For functions with many attributes, `{` on its
  own line is acceptable.
* Use UFCS liberally.
* Always re-read files before editing; another agent or person may have
  changed them in the meantime.
* Trailing commas.
* Maximise attributes: `@safe @nogc nothrow pure const scope`. Do not
  abuse `@trusted` to make functions `@safe`.
* Private functions below their first use, as close as possible.
* Prefer `std.conv.text`; use `text(x)` not `x.to!string`.
* Make parameters `in` if possible.
* Prefer `const`; use `auto` with a comment if `const` fails; explicit
  LHS type only if `auto` fails (comment why). Explicit types are fine
  for uninitialised declarations.
* No `synchronized`.
* Omit empty parens: `doStuff;` not `doStuff();`.
* Variables as close to their usage as possible.
* Use `with` in `switch`/`final switch` with enums for more readability.
* private variables start with an underscore, e.g. `_member`.
* D has modules and types within types, do not use C-like naming
  conventions like `Foo` and `FooEnum`, instead place enums inside the
  corresponding class/struct so that one uses `Foo.Enum` instead.

### Production code (in `source`)

- Use `imported!"module"` for parameter and return types at
  module-scope.  Do not use `imported!"module"` in non-module scopes
  such as inside a function, struct, or class.
- `private:` at top of every module; still annotate each declaration
  explicitly with `public`/`private`.
- Do not use exceptions for control flow.

### Test modules (in `tests`)

- Use module-scope imports to avoid repeating the same import in every
  test block. Unit test modules should not use `imported`.
- Use package modules liberally to avoid imports in test modules - see
  `import ut;` for a good example.

## Code organisation

* Backends must not import each other: nothing in one backend's package
  may import another backend's package, and vice versa. Within a single
  backend package, modules can and should import each other, including
  package-private code.

# Testing

Run `dub run reggae --compiler=ldc -- -b ninja` if `build.ninja` does not
exist, then `ninja bin/ut`, then `bin/ut --random` after every editing session.
If the sandbox blocks these commands, request escalation for the same command
instead of trying alternate test runners. Do not substitute `ut`, `./ut`, or
another build command for the required `ninja bin/ut` and `bin/ut --random`
commands unless the user explicitly asks for a focused unit-threaded run. We're
using `--random` because in this project the tests run serially. If there's a
test failure, first check with `--seed` (using the seed in the output to the
last `bin/ut --random`) to investigate the cause of failure in that particular
ordering.

Run `ci.sh` before creating a PR. If the benchmarks fail to run
properly for any backend, identify why and come up with a D language
feature unit test that exposes the flaw in that backend's
implementation.

No per-test process spawning, network access, or repeated dependency
resolution unless explicitly approved.

Never delete test code to make tests pass.

# Do nots

- Add new mistakes to `ai/mistakes.md`. New ones only — no duplicates.
- No classes unless the goal is OOP (virtual dispatch, inheritance). A
  class with no base, no children, and no virtual methods is a struct.

# Do

- Read `ai/mistakes.md` before starting.
- Read git history when starting a new session.
- Wrap markdown files at 80 columns.

## Github

- Label PR comments as from an agent (identify which one).
- Open new PRs in the browser.
- Check for local worktrees before using `gh` to look at diffs etc.
- When you create a PR, check to see if it can be merged and fix any
  conflicts, don't wait to be told to do so.

## CI

The repo is private for now, which is causing Github Actions failures
due to billing issues. CI is not currently checking anything we can't
and don't do locally, so ignore its failures for as long as the repo
is private.

## Reviews

Present review findings one by one for discussion and approval. This
applies to reviewing code or plans.

# General LLM Coding Guidelines inspired by Andrej Karpathy

## Source

<https://github.com/multica-ai/andrej-karpathy-skills>

# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with
project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For
trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick
  silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?"
If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's
request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them
  pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria
("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in
diffs, fewer rewrites due to overcomplication, and clarifying
questions come before implementation rather than after mistakes.
